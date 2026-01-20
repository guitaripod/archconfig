return {
  "wojciech-kulik/xcodebuild.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "MunifTanjim/nui.nvim",
    "folke/snacks.nvim",
    "nvim-tree/nvim-tree.lua",
    "nvim-treesitter/nvim-treesitter",
  },
  config = function()
    require("xcodebuild").setup({
      restore_on_start = true,
      auto_save = true,
      show_build_progress_bar = true,
      prepare_snapshot_test_previews = true,
      test_search = {
        file_matching = "filename_lsp",
        target_matching = true,
        lsp_client = "sourcekit",
        lsp_timeout = 200,
      },
      commands = {
        extra_build_args = { "-parallelizeTargets" },
        extra_test_args = { "-parallelizeTargets" },
        project_search_max_depth = 4,
        focus_simulator_on_app_launch = true,
      },
      logs = {
        auto_open_on_success_tests = false,
        auto_open_on_failed_tests = false,
        auto_open_on_success_build = false,
        auto_open_on_failed_build = true,
        auto_close_on_app_launch = false,
        auto_close_on_success_build = false,
        auto_focus = true,
        filetype = "",
        open_command = "silent botright 20split {path}",
        logs_formatter = "xcbeautify --disable-colored-output --disable-logging",
        only_summary = false,
        live_logs = true,
        show_warnings = true,
        notify = function(message, severity)
          vim.notify(message, severity)
        end,
        notify_progress = function(message)
          vim.cmd("echo '" .. message .. "'")
        end,
      },
      console_logs = {
        enabled = true,
        format_line = function(line)
          return line
        end,
        filter_line = function(line)
          return true
        end,
      },
      marks = {
        show_signs = true,
        success_sign = "✔",
        failure_sign = "✖",
        show_test_duration = true,
        show_diagnostics = true,
      },
      quickfix = {
        show_errors_on_quickfixlist = true,
        show_warnings_on_quickfixlist = true,
      },
      test_explorer = {
        enabled = true,
        auto_open = true,
        auto_focus = true,
        open_command = "botright 42vsplit Test Explorer",
        open_expanded = true,
        success_sign = "✔",
        failure_sign = "✖",
        progress_sign = "…",
        disabled_sign = "⏸",
        partial_execution_sign = "‐",
        not_executed_sign = " ",
        show_disabled_tests = false,
        animate_status = true,
        cursor_follows_tests = true,
      },
      code_coverage = {
        enabled = false,
        file_pattern = "*.swift",
        covered_sign = "",
        partially_covered_sign = "┃",
        not_covered_sign = "┃",
        not_executable_sign = "",
      },
      code_coverage_report = {
        warning_coverage_level = 60,
        error_coverage_level = 30,
        open_expanded = false,
      },
      integrations = {
        pymobiledevice = {
          enabled = true,
          remote_debugger_port = 65123,
        },
        xcodebuild_offline = {
          enabled = false,
        },
        xcode_build_server = {
          enabled = true,
          guess_scheme = false,
        },
        nvim_tree = {
          enabled = true,
        },
        neo_tree = {
          enabled = true,
        },
        oil_nvim = {
          enabled = true,
        },
        quick = {
          enabled = true,
        },
      },
    })

    -- Xcodebuild keymaps
    vim.keymap.set("n", "<leader>X", "<cmd>XcodebuildPicker<cr>", { desc = "Show Xcodebuild Actions" })
    vim.keymap.set("n", "<leader>xf", "<cmd>XcodebuildProjectManager<cr>", { desc = "Show Project Manager Actions" })

    vim.keymap.set("n", "<leader>xb", "<cmd>XcodebuildBuild<cr>", { desc = "Build Project" })
    vim.keymap.set("n", "<leader>xB", "<cmd>XcodebuildBuildForTesting<cr>", { desc = "Build For Testing" })
    vim.keymap.set("n", "<leader>xr", "<cmd>XcodebuildBuildRun<cr>", { desc = "Build & Run Project" })

    vim.keymap.set("n", "<leader>xt", "<cmd>XcodebuildTest<cr>", { desc = "Run Tests" })
    vim.keymap.set("v", "<leader>xt", "<cmd>XcodebuildTestSelected<cr>", { desc = "Run Selected Tests" })
    vim.keymap.set("n", "<leader>xT", "<cmd>XcodebuildTestClass<cr>", { desc = "Run Current Test Class" })
    vim.keymap.set("n", "<leader>x.", "<cmd>XcodebuildTestRepeat<cr>", { desc = "Repeat Last Test Run" })

    vim.keymap.set("n", "<leader>xl", "<cmd>XcodebuildToggleLogs<cr>", { desc = "Toggle Xcodebuild Logs" })
    vim.keymap.set("n", "<leader>xc", "<cmd>XcodebuildToggleCodeCoverage<cr>", { desc = "Toggle Code Coverage" })
    vim.keymap.set("n", "<leader>xC", "<cmd>XcodebuildShowCodeCoverageReport<cr>", { desc = "Show Code Coverage Report" })
    vim.keymap.set("n", "<leader>xe", "<cmd>XcodebuildTestExplorerToggle<cr>", { desc = "Toggle Test Explorer" })
    vim.keymap.set("n", "<leader>xs", "<cmd>XcodebuildFailingSnapshots<cr>", { desc = "Show Failing Snapshots" })

    vim.keymap.set("n", "<leader>xp", "<cmd>XcodebuildPreviewGenerateAndShow<cr>", { desc = "Generate Preview" })
    vim.keymap.set("n", "<leader>x<cr>", "<cmd>XcodebuildPreviewToggle<cr>", { desc = "Toggle Preview" })

    vim.keymap.set("n", "<leader>xd", "<cmd>XcodebuildSelectDevice<cr>", { desc = "Select Device" })
    vim.keymap.set("n", "<leader>xq", "<cmd>Telescope quickfix<cr>", { desc = "Show QuickFix List" })

    vim.keymap.set("n", "<leader>xx", "<cmd>XcodebuildQuickfixLine<cr>", { desc = "Quickfix Line" })
    vim.keymap.set("n", "<leader>xa", "<cmd>XcodebuildCodeActions<cr>", { desc = "Show Code Actions" })
  end,
}