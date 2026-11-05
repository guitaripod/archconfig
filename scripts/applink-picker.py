#!/usr/bin/python3
"""Telescope-style picker for applink: prints the chosen App Store link on stdout, exits 1 on cancel."""

import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from PyQt6.QtCore import QAbstractListModel, QEvent, QModelIndex, QObject, QPoint, QRectF, QSize, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QFontMetricsF, QIcon, QPainter, QPainterPath, QPalette, QPixmap
from PyQt6.QtWidgets import (
    QApplication,
    QFrame,
    QGraphicsDropShadowEffect,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListView,
    QStyle,
    QStyledItemDelegate,
    QVBoxLayout,
    QWidget,
)

HOME = Path.home()
LINKS = HOME / ".config/applink/links.tsv"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "applink"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "applink"
RECENT = STATE_DIR / "recent"
META = CACHE_DIR / "meta.json"
ICONS = CACHE_DIR / "icons"
LOOKUP_URL = "https://itunes.apple.com/lookup?id={ids}&country=us"
META_MAX_AGE = 7 * 24 * 3600

WIDTH = 460
ROW_HEIGHT = 52
VISIBLE_ROWS = 8
ICON_SIZE = 34
SHADOW = 24
RADIUS = 14
HALF_PAGE = VISIBLE_ROWS // 2
INSERT_GREEN = QColor("#27ae60")


@dataclass
class Link:
    code: str
    name: str
    url: str
    subtitle: str = ""
    name_hits: list[int] = field(default_factory=list)
    subtitle_hits: list[int] = field(default_factory=list)

    @property
    def track_id(self) -> str:
        found = re.search(r"/id(\d+)", self.url)
        return found.group(1) if found else ""


def read_links(path: Path) -> tuple[list[Link], list[int]]:
    """Valid rows of links.tsv (code, name, https URL) and the line numbers of malformed ones."""
    links, bad = [], []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not parts[0] or not parts[1] or not parts[2].startswith("https://"):
            bad.append(number)
            continue
        links.append(Link(parts[0], parts[1], parts[2]))
    return links, bad


def read_recent() -> list[str]:
    try:
        return RECENT.read_text(encoding="utf-8").split()
    except OSError:
        return []


def remember(code: str, known: set[str]) -> None:
    """Move code to the front of the recent list, dropping codes that left links.tsv."""
    order = [code] + [c for c in read_recent() if c != code and c in known]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RECENT.write_text("\n".join(order) + "\n", encoding="utf-8")


def read_meta() -> dict:
    try:
        return json.loads(META.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def icon_path(track_id: str) -> Path | None:
    matches = sorted(ICONS.glob(f"{track_id}.*"))
    return matches[0] if matches else None


def needs_refresh(links: list[Link], meta: dict) -> bool:
    """True when an app has no cached subtitle or icon, or the cache is a week old."""
    try:
        stale = time.time() - META.stat().st_mtime > META_MAX_AGE
    except OSError:
        stale = True
    return stale or any(l.track_id not in meta or icon_path(l.track_id) is None for l in links)


def subtitle_from(track_name: str, name: str, genre: str) -> str:
    """The part of an App Store title after the app's name ("Tailscode: Coding Agent Remote"), else its genre."""
    found = re.match(r"^.*?\s*[:–—-]\s+(.+)$", track_name)
    if found:
        return found.group(1)
    rest = track_name[len(name):].strip() if track_name.lower().startswith(name.lower()) else ""
    return rest or genre


def fetch_meta(links: list[Link]) -> dict:
    """Look every app up on the iTunes API, cache its subtitle and a 128 px icon, and return the new metadata."""
    ids = ",".join(l.track_id for l in links if l.track_id)
    with urllib.request.urlopen(LOOKUP_URL.format(ids=ids), timeout=6) as response:
        results = json.load(response).get("results", [])
    ICONS.mkdir(parents=True, exist_ok=True)
    names = {l.track_id: l.name for l in links}
    meta = {}
    for result in results:
        track_id = str(result.get("trackId", ""))
        art = result.get("artworkUrl512") or result.get("artworkUrl100") or ""
        title = result.get("trackName", "")
        meta[track_id] = {"subtitle": subtitle_from(title, names.get(track_id, ""), result.get("primaryGenreName", ""))}
        if art:
            art = re.sub(r"/\d+x\d+bb\.", "/128x128bb.", art)
            suffix = Path(art).suffix or ".png"
            with urllib.request.urlopen(art, timeout=6) as response:
                data = response.read()
            for old in ICONS.glob(f"{track_id}.*"):
                old.unlink()
            (ICONS / f"{track_id}{suffix}").write_bytes(data)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    META.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return meta


def fuzzy(query: str, text: str) -> tuple[float, list[int]] | None:
    """fzf-style score of query in text: contiguous and word-start hits rank highest; None when it is not a subsequence."""
    q, t = query.lower(), text.lower()
    if not q:
        return 0.0, []
    start = t.find(q)
    if start >= 0:
        at_word = start == 0 or not t[start - 1].isalnum()
        return 100.0 + (50 if at_word else 0) - start, list(range(start, start + len(q)))
    hits, score, cursor = [], 0.0, 0
    for ch in q:
        found = t.find(ch, cursor)
        if found < 0:
            return None
        if hits and found == hits[-1] + 1:
            score += 8
        if found == 0 or not t[found - 1].isalnum():
            score += 6
        score -= (found - cursor) * 0.5
        hits.append(found)
        cursor = found + 1
    return score, hits


def rank(links: list[Link], query: str) -> list[Link]:
    """Links matching query, best first; name hits outrank subtitle hits, ties keep the incoming order."""
    if not query:
        for link in links:
            link.name_hits, link.subtitle_hits = [], []
        return list(links)
    scored = []
    for position, link in enumerate(links):
        by_name = fuzzy(query, link.name)
        by_subtitle = fuzzy(query, link.subtitle)
        link.name_hits = by_name[1] if by_name else []
        link.subtitle_hits = by_subtitle[1] if by_subtitle and not by_name else []
        if by_name:
            scored.append((by_name[0] + 40, position, link))
        elif by_subtitle:
            scored.append((by_subtitle[0], position, link))
    scored.sort(key=lambda entry: (-entry[0], entry[1]))
    return [link for _, _, link in scored]


class LinkModel(QAbstractListModel):
    def __init__(self) -> None:
        super().__init__()
        self.items: list[Link] = []

    def rowCount(self, parent=QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self.items)

    def data(self, index, role=Qt.ItemDataRole.DisplayRole):
        if not index.isValid():
            return None
        link = self.items[index.row()]
        if role == Qt.ItemDataRole.DisplayRole:
            return link.name
        if role == Qt.ItemDataRole.UserRole:
            return link
        return None

    def replace(self, items: list[Link]) -> None:
        self.beginResetModel()
        self.items = items
        self.endResetModel()


class Fetcher(QObject):
    fetched = pyqtSignal(dict)

    def start(self, links: list[Link]) -> None:
        threading.Thread(target=self._run, args=(links,), daemon=True).start()

    def _run(self, links: list[Link]) -> None:
        try:
            self.fetched.emit(fetch_meta(links))
        except Exception as err:
            print(f"applink-picker: icon refresh failed: {err}", file=sys.stderr)


class RowDelegate(QStyledItemDelegate):
    def __init__(self, picker: "Picker") -> None:
        super().__init__(picker)
        self.picker = picker

    def sizeHint(self, option, index) -> QSize:
        return QSize(WIDTH, ROW_HEIGHT)

    def paint(self, painter: QPainter, option, index) -> None:
        link: Link = index.data(Qt.ItemDataRole.UserRole)
        palette = self.picker.palette()
        rect = QRectF(option.rect).adjusted(8, 2, -8, -2)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        if selected:
            tint = QColor(palette.color(QPalette.ColorRole.Highlight))
            tint.setAlpha(48)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(tint)
            painter.drawRoundedRect(rect, 10, 10)
        icon_rect = QRectF(rect.left() + 10, rect.center().y() - ICON_SIZE / 2, ICON_SIZE, ICON_SIZE)
        self._paint_icon(painter, icon_rect, link)
        text_left = icon_rect.right() + 14
        number_width = self._paint_number(painter, rect, index.row(), palette)
        text_width = rect.right() - text_left - number_width - 8
        base = self.picker.font()
        name_font = QFont(base)
        name_font.setPointSizeF(base.pointSizeF() + 1.5)
        name_font.setWeight(QFont.Weight.DemiBold)
        sub_font = QFont(base)
        sub_font.setPointSizeF(base.pointSizeF() - 0.5)
        name_metrics, sub_metrics = QFontMetricsF(name_font), QFontMetricsF(sub_font)
        block = name_metrics.height() + 2 + sub_metrics.height()
        top = rect.center().y() - block / 2
        text = palette.color(QPalette.ColorRole.Text)
        muted = palette.color(QPalette.ColorRole.PlaceholderText)
        accent = palette.color(QPalette.ColorRole.Highlight)
        self._paint_marked(painter, link.name, link.name_hits, name_font, text, accent, text_left, top + name_metrics.ascent(), text_width)
        sub_baseline = top + name_metrics.height() + 2 + sub_metrics.ascent()
        self._paint_marked(painter, link.subtitle, link.subtitle_hits, sub_font, muted, accent, text_left, sub_baseline, text_width)
        painter.restore()

    def _paint_icon(self, painter: QPainter, rect: QRectF, link: Link) -> None:
        """The cached App Store icon clipped to an iOS-style rounded square, or a tinted initial until it is cached."""
        path = QPainterPath()
        path.addRoundedRect(rect, ICON_SIZE * 0.23, ICON_SIZE * 0.23)
        pixmap = self.picker.icon_for(link)
        painter.save()
        painter.setClipPath(path)
        if pixmap is not None:
            painter.drawPixmap(rect.toRect(), pixmap)
        else:
            painter.fillRect(rect, QColor.fromHsv(sum(map(ord, link.name)) * 37 % 360, 120, 200))
            initial = QFont(self.picker.font())
            initial.setPointSizeF(ICON_SIZE * 0.42)
            initial.setWeight(QFont.Weight.Bold)
            painter.setFont(initial)
            painter.setPen(Qt.GlobalColor.white)
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, link.name[:1].upper())
        painter.restore()
        edge = QColor(0, 0, 0, 28)
        painter.setPen(edge)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

    def _paint_number(self, painter: QPainter, rect: QRectF, row: int, palette: QPalette) -> float:
        """Vim-style relative line numbers in normal mode; returns the width they take."""
        if self.picker.mode != "normal":
            return 0.0
        current = self.picker.list.currentIndex().row()
        label = str(row + 1) if row == current else str(abs(row - current))
        font = QFont("monospace")
        font.setStyleHint(QFont.StyleHint.Monospace)
        font.setPointSizeF(self.picker.font().pointSizeF() - 1)
        painter.setFont(font)
        color = palette.color(QPalette.ColorRole.Text if row == current else QPalette.ColorRole.PlaceholderText)
        painter.setPen(color)
        width = QFontMetricsF(font).horizontalAdvance("00")
        painter.drawText(QRectF(rect.right() - width - 12, rect.top(), width, rect.height()), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, label)
        return width + 12

    def _paint_marked(self, painter, text, hits, font, color, accent, x, baseline, width) -> None:
        """Draw text with the fuzzy-matched characters in the accent colour, eliding what does not fit."""
        metrics = QFontMetricsF(font)
        if metrics.horizontalAdvance(text) > width:
            text = metrics.elidedText(text, Qt.TextElideMode.ElideRight, width)
        marked = set(hits)
        bold = QFont(font)
        bold.setWeight(QFont.Weight.Black)
        cursor = x
        for i, ch in enumerate(text):
            hit = i in marked
            painter.setFont(bold if hit else font)
            painter.setPen(accent if hit else color)
            painter.drawText(QRectF(cursor, baseline - metrics.ascent(), width, metrics.height() + 2), Qt.AlignmentFlag.AlignLeft, ch)
            cursor += QFontMetricsF(bold if hit else font).horizontalAdvance(ch)


class Card(QFrame):
    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        border = QColor(self.palette().color(QPalette.ColorRole.Text))
        border.setAlpha(40)
        painter.setPen(border)
        painter.setBrush(self.palette().color(QPalette.ColorRole.Window))
        painter.drawRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), RADIUS, RADIUS)


class Picker(QWidget):
    def __init__(self, links: list[Link], recent: list[str]) -> None:
        super().__init__(None, Qt.WindowType.Window | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowTitle("App Link")
        order = {code: i for i, code in enumerate(recent)}
        self.links = sorted(links, key=lambda l: (order.get(l.code, len(order)), links.index(l)))
        self.known = {l.code for l in links}
        self.mode = "insert"
        self.count = ""
        self.pending_g = False
        self.chosen: Link | None = None
        self.was_active = False
        self.hover_origin: QPoint | None = None
        self.hover_armed = False
        self.icons: dict[str, QPixmap] = {}
        self._apply_meta(read_meta())
        self._build()
        self._refilter()
        if needs_refresh(self.links, read_meta()):
            self.fetcher = Fetcher()
            self.fetcher.fetched.connect(self._on_fetched)
            self.fetcher.start(self.links)

    def _build(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(SHADOW, SHADOW - 6, SHADOW, SHADOW + 6)
        card = Card(self)
        shadow = QGraphicsDropShadowEffect(card)
        shadow.setBlurRadius(SHADOW * 1.6)
        shadow.setOffset(0, 6)
        shadow.setColor(QColor(0, 0, 0, 90))
        card.setGraphicsEffect(shadow)
        outer.addWidget(card)
        layout = QVBoxLayout(card)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        prompt = QHBoxLayout()
        prompt.setContentsMargins(18, 14, 14, 12)
        prompt.setSpacing(10)
        glass = QLabel()
        glass.setPixmap(QIcon.fromTheme("search", QIcon.fromTheme("edit-find")).pixmap(18, 18))
        self.query = QLineEdit()
        self.query.setFrame(False)
        self.query.setPlaceholderText("Search apps")
        query_font = QFont(self.font())
        query_font.setPointSizeF(self.font().pointSizeF() + 3)
        self.query.setFont(query_font)
        transparent = self.query.palette()
        transparent.setColor(QPalette.ColorRole.Base, Qt.GlobalColor.transparent)
        self.query.setPalette(transparent)
        self.query.textChanged.connect(self._refilter)
        self.query.installEventFilter(self)
        self.counter = QLabel()
        self.counter.setStyleSheet(f"color: {self._muted().name()};")
        self.pending = QLabel()
        pending_font = QFont("monospace")
        pending_font.setStyleHint(QFont.StyleHint.Monospace)
        self.pending.setFont(pending_font)
        self.pending.setStyleSheet(f"color: {self.palette().color(QPalette.ColorRole.Highlight).name()}; font-weight: 700;")
        self.badge = QLabel()
        self.badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.badge.setFixedHeight(22)
        prompt.addWidget(glass)
        prompt.addWidget(self.query, 1)
        prompt.addWidget(self.pending)
        prompt.addWidget(self.counter)
        prompt.addWidget(self.badge)
        layout.addLayout(prompt)
        layout.addWidget(self._rule())

        self.model = LinkModel()
        self.list = QListView()
        self.list.setModel(self.model)
        self.list.setItemDelegate(RowDelegate(self))
        self.list.setFrameShape(QFrame.Shape.NoFrame)
        self.list.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.list.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.list.setMouseTracking(True)
        self.list.setUniformItemSizes(True)
        self.list.viewport().setAutoFillBackground(False)
        self.list.setStyleSheet("QListView { background: transparent; }")
        self.list.setFixedHeight(ROW_HEIGHT * min(VISIBLE_ROWS, max(1, len(self.links))))
        self.list.entered.connect(self._on_hover)
        self.list.clicked.connect(lambda index: self._pick(index.row()))
        self.list.viewport().installEventFilter(self)
        self.empty = QLabel("No matching app", self.list)
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setStyleSheet(f"color: {self._muted().name()};")
        layout.addSpacing(6)
        layout.addWidget(self.list)
        layout.addSpacing(6)
        layout.addWidget(self._rule())

        self.hints = QLabel()
        self.hints.setContentsMargins(18, 8, 18, 10)
        hint_font = QFont(self.font())
        hint_font.setPointSizeF(self.font().pointSizeF() - 1)
        self.hints.setFont(hint_font)
        layout.addWidget(self.hints)
        card.setFixedWidth(WIDTH)
        self._set_mode("insert")

    def _rule(self) -> QFrame:
        line = QFrame()
        line.setFixedHeight(1)
        color = QColor(self.palette().color(QPalette.ColorRole.Text))
        color.setAlpha(28)
        line.setStyleSheet(f"background: rgba({color.red()},{color.green()},{color.blue()},{color.alpha()});")
        return line

    def _muted(self) -> QColor:
        return self.palette().color(QPalette.ColorRole.PlaceholderText)

    def _apply_meta(self, meta: dict) -> None:
        for link in self.links:
            entry = meta.get(link.track_id)
            if entry:
                link.subtitle = entry.get("subtitle", "")
        self.icons.clear()

    def _on_fetched(self, meta: dict) -> None:
        self._apply_meta(meta)
        self._refilter()

    def icon_for(self, link: Link) -> QPixmap | None:
        if link.track_id not in self.icons:
            path = icon_path(link.track_id)
            pixmap = QPixmap(str(path)) if path else QPixmap()
            if pixmap.isNull():
                return None
            ratio = self.devicePixelRatioF()
            pixmap = pixmap.scaled(round(ICON_SIZE * ratio), round(ICON_SIZE * ratio), Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
            pixmap.setDevicePixelRatio(ratio)
            self.icons[link.track_id] = pixmap
        return self.icons[link.track_id]

    def _refilter(self) -> None:
        current = self.list.currentIndex().row() if self.model.items else -1
        keep = self.model.items[current].code if 0 <= current < len(self.model.items) and not self.query.text() else None
        items = rank(self.links, self.query.text().strip())
        self.model.replace(items)
        row = next((i for i, l in enumerate(items) if l.code == keep), 0)
        if items:
            self._select(row)
        self.empty.setVisible(not items)
        self.empty.setGeometry(self.list.viewport().rect())
        self.counter.setText(f"{len(items)}/{len(self.links)}")

    def _select(self, row: int) -> None:
        if not self.model.items:
            return
        row = max(0, min(row, len(self.model.items) - 1))
        index = self.model.index(row)
        self.list.setCurrentIndex(index)
        self.list.scrollTo(index)
        self.list.viewport().update()

    def _move(self, delta: int) -> None:
        self._select(self.list.currentIndex().row() + delta)

    def _set_mode(self, mode: str) -> None:
        self.mode = mode
        self.count = ""
        self.pending_g = False
        self._show_pending()
        insert = mode == "insert"
        self.query.setReadOnly(not insert)
        color = INSERT_GREEN if insert else self.palette().color(QPalette.ColorRole.Highlight)
        self.badge.setText("INSERT" if insert else "NORMAL")
        self.badge.setStyleSheet(
            f"background: {color.name()}; color: white; border-radius: 6px; padding: 0 8px;"
            f" font-weight: 700; font-size: {max(7.0, self.font().pointSizeF() - 1.5):.1f}pt; letter-spacing: 0.5px;"
        )
        keys = (
            [("⏎", "paste"), ("^j ^k", "move"), ("esc", "normal"), ("^c", "close")]
            if insert
            else [("⏎", "paste"), ("j k", "move"), ("gg G", "jump"), ("i /", "search"), ("q", "close")]
        )
        muted = self._muted().name()
        text = self.palette().color(QPalette.ColorRole.Text).name()
        self.hints.setText(
            "&nbsp;&nbsp;&nbsp;".join(f"<span style='color:{text}; font-weight:600'>{k}</span> <span style='color:{muted}'>{v}</span>" for k, v in keys)
        )
        self.list.viewport().update()

    def _pick(self, row: int) -> None:
        if 0 <= row < len(self.model.items):
            self.chosen = self.model.items[row]
            self.close()

    def _on_hover(self, index: QModelIndex) -> None:
        if self.hover_armed and index.isValid():
            self._select(index.row())

    def eventFilter(self, watched, event) -> bool:
        if event.type() == QEvent.Type.KeyPress and watched is self.query:
            return self._key(event)
        if event.type() == QEvent.Type.MouseMove and watched is self.list.viewport():
            self._arm_hover(event.position().toPoint())
            return False
        return super().eventFilter(watched, event)

    def _arm_hover(self, position: QPoint) -> None:
        """Ignore the pointer the window opened under until it really moves, so it cannot override the preselected row."""
        if self.hover_armed:
            return
        if self.hover_origin is None:
            self.hover_origin = position
        elif (position - self.hover_origin).manhattanLength() > 6:
            self.hover_armed = True
            self._on_hover(self.list.indexAt(position))

    def _key(self, event) -> bool:
        key, mods, text = event.key(), event.modifiers(), event.text()
        ctrl = bool(mods & Qt.KeyboardModifier.ControlModifier)
        if ctrl and key == Qt.Key.Key_C:
            self.close()
            return True
        if key in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._pick(self.list.currentIndex().row())
            return True
        if key == Qt.Key.Key_Down or (ctrl and key in (Qt.Key.Key_J, Qt.Key.Key_N)) or (key == Qt.Key.Key_Tab and not ctrl):
            self._move(self._take_count())
            return True
        if key in (Qt.Key.Key_Up, Qt.Key.Key_Backtab) or (ctrl and key in (Qt.Key.Key_K, Qt.Key.Key_P)):
            self._move(-self._take_count())
            return True
        if ctrl and key == Qt.Key.Key_D:
            self._move(HALF_PAGE)
            return True
        if ctrl and key == Qt.Key.Key_U and self.mode == "normal":
            self._move(-HALF_PAGE)
            return True
        if self.mode == "insert":
            return self._insert_key(key, ctrl)
        return self._normal_key(key, ctrl, text)

    def _insert_key(self, key: int, ctrl: bool) -> bool:
        if key == Qt.Key.Key_Escape:
            self._set_mode("normal")
            return True
        if ctrl and key == Qt.Key.Key_U:
            self.query.clear()
            return True
        if ctrl and key == Qt.Key.Key_W:
            before = self.query.text()[: self.query.cursorPosition()]
            trimmed = re.sub(r"\S*\s*$", "", before)
            self.query.setText(trimmed + self.query.text()[len(before):])
            self.query.setCursorPosition(len(trimmed))
            return True
        return False

    def _normal_key(self, key: int, ctrl: bool, text: str) -> bool:
        if key == Qt.Key.Key_Escape or text == "q":
            self.close()
        elif text.isdigit() and (self.count or text != "0"):
            self.count += text
            self.list.viewport().update()
        elif text == "j":
            self._move(self._take_count())
        elif text == "k":
            self._move(-self._take_count())
        elif text == "l":
            self._pick(self.list.currentIndex().row())
        elif text == "G":
            target = int(self.count) - 1 if self.count else len(self.model.items) - 1
            self.count = ""
            self._select(target)
        elif text == "g":
            if self.pending_g:
                target = int(self.count) - 1 if self.count else 0
                self.count = ""
                self._select(target)
            self.pending_g = not self.pending_g
            self._show_pending()
            return True
        elif text in ("i", "a", "/", "I", "A"):
            self._set_mode("insert")
            self.query.setCursorPosition(0 if text == "I" else len(self.query.text()))
            if text == "/":
                self.query.selectAll()
        self.pending_g = False
        self._show_pending()
        return True

    def _take_count(self) -> int:
        count = int(self.count) if self.count else 1
        self.count = ""
        return count

    def _show_pending(self) -> None:
        """Vim's showcmd: the count and g typed so far in normal mode."""
        self.pending.setText(self.count + ("g" if self.pending_g else ""))

    def changeEvent(self, event) -> None:
        if event.type() == QEvent.Type.ActivationChange:
            if self.isActiveWindow():
                self.was_active = True
            elif self.was_active and self.chosen is None:
                self.close()
        super().changeEvent(event)

    def mousePressEvent(self, event) -> None:
        card = self.childAt(event.position().toPoint())
        if card is None:
            self.close()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        QTimer.singleShot(0, self._focus)

    def _focus(self) -> None:
        self.activateWindow()
        self.raise_()
        self.query.setFocus()


def notify(message: str) -> None:
    subprocess.run(["notify-send", "-a", "App Link", "App Link", message], check=False)


def main() -> int:
    if not LINKS.is_file():
        notify(f"Missing {LINKS}")
        return 1
    links, bad = read_links(LINKS)
    if bad:
        notify(f"Skipped malformed lines in {LINKS}: {' '.join(map(str, bad))}")
    if not links:
        notify(f"No links in {LINKS}")
        return 1
    app = QApplication(sys.argv)
    app.setApplicationName("applink")
    app.setDesktopFileName("applink")
    picker = Picker(links, read_recent())
    picker.show()
    app.exec()
    if picker.chosen is None:
        return 1
    remember(picker.chosen.code, picker.known)
    print(picker.chosen.url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
