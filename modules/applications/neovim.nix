{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
with lib; let
  cfg = config.sifr.applications;
in {
  options.sifr.applications.neovim.enable = mkOption {
    description = "Enables neovim configurations";
    type = types.bool;
    default = true;
  };
  config = mkMerge [
    (mkIf cfg.neovim.enable {
      home-manager.users."${vars.user}" = let
        inherit (config.home-manager.users."${vars.user}".xdg) configHome;
      in {
        programs.nixvim = {
          enable = true;
          colorscheme = "tokyonight-night";
          autoCmd = [
            # Tab = 2 spaces
            {
              event = ["FileType"];
              pattern = [
                "css"
                "javascript"
                "javascriptreact"
                "typescriptreact"
                "html"
                "yaml"
              ];
              command = "setlocal et ts=2 sw=2";
            }
            # Tab = 4 spaces
            {
              event = ["FileType"];
              pattern = ["python"];
              command = "setlocal et ts=4 sw=4";
            }
            # Tab = 4-col Tab
            {
              event = ["FileType"];
              pattern = ["go"];
              command = "setlocal ts=4 sw=4";
            }
          ];
          opts = {
            # Character encoding
            encoding = "utf-8";
            fileencoding = "utf-8";
            fileencodings = ["utf-8"];

            # Show whitespace characters
            listchars = "tab:▸\\ ,eol:¬,space:.";

            # Line number
            number = true;

            # Line width
            colorcolumn = [80];
            #textwidth = 79; # Annoying sometimes

            # Disable splash screen
            #shm = [ "I" ];

            # Tabs
            expandtab = false;
            tabstop = 2;
            shiftwidth = 2;
            smartindent = true;

            # Automatically read file when updated
            autoread = true;

            # Backup dir
            backupdir = "${configHome}/.cache";
            directory = "${configHome}/.cache";

            # Undo file
            undofile = true;
            undodir = "${configHome}/nvim/vimundo";
            undolevels = 10000;
            undoreload = 10000;
          };
          plugins = {
            lsp = {
              enable = true;
              servers = {
                # Programming & Scripts
                golangci-lint-ls.enable = true;
                gopls.enable = true;
                bashls.enable = true;
                nixd.enable = true;
                clangd.enable = true;
                rust-analyzer.enable = true;
                pyright.enable = true;

                # Markup & Config
                marksman.enable = true;
                jsonls.enable = true;
                yamlls.enable = true;

                # Web
                html.enable = true;
                eslint.enable = true;
                cssls.enable = true;
                tsserver.enable = true;
              };
            };

            vim-css-color.enable = true;
            surround.enable = true;
            fugitive.enable = true;
            commentary.enable = true;

            # TODO configure
            telescope.enable = true;

            vimtex.enable = true;
            nix.enable = true;

            luasnip.enable = true;
            cmp.enable = true;
            cmp-nvim-lsp.enable = true;
            cmp-path.enable = true;
            cmp-buffer.enable = true;
            hardtime.enable = true;
            neogit.enable = true;

            gitsigns.enable = true;
            dashboard = {
              enable = true;
              header = ["Welcome to your editor"];
            };

            # Need to renew subscription :)
            #copilot-vim.enable = true; # GtHub Copilot
          };

          extraPlugins = with pkgs.vimPlugins; [
            plenary-nvim
            #vim-css-color
            vim-repeat
            #vim-surround
            #vim-fugitive
            #vim-commentary
            #telescope-nvim
            #vimtex

            # Auto completion
            neodev-nvim
            #luasnip
            lsp-zero-nvim
            nvim-lspconfig
            #nvim-cmp
            #cmp-nvim-lsp

            #cmp-path
            #cmp-buffer
            #copilot-vim # GitHub copilot

            # Theme
            tokyonight-nvim
          ];
        };
      };
    })
  ];
}
