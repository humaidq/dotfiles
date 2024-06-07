{
  config,
  lib,
  vars,
  pkgs,
  ...
}: let
  cfg = config.sifr.applications;
  dev = config.sifr.development.enable;
in {
  options.sifr.applications.neovim.enable = lib.mkOption {
    description = "Enables neovim configurations";
    type = lib.types.bool;
    default = true;
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.neovim.enable {
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
              enable = dev;
              servers = {
                # Programming & Scripts
                golangci-lint-ls.enable = dev;
                gopls.enable = dev;
                bashls.enable = dev;
                nixd.enable = dev;
                clangd.enable = dev;
                rust-analyzer = {
                  enable = dev;
                  installCargo = dev;
                  installRustc = dev;
                };
                pyright.enable = dev;

                # Markup & Config
                marksman.enable = dev;
                jsonls.enable = dev;
                yamlls.enable = dev;

                # Web
                html.enable = dev;
                eslint.enable = dev;
                cssls.enable = dev;
                tsserver.enable = dev;
              };
            };

            vim-css-color.enable = true;
            surround.enable = true;
            fugitive.enable = true;
            commentary.enable = true;

            # TODO configure
            telescope.enable = true;

            vimtex.enable = dev;
            nix.enable = true;

            luasnip.enable = true;
            cmp.enable = true;
            cmp-nvim-lsp.enable = true;
            cmp-path.enable = true;
            cmp-buffer.enable = true;
            hardtime.enable = false;
            #neogit.enable = true;

            gitsigns.enable = true;
            dashboard = {
              enable = true;
              header = ["Welcome to your editor"];
            };

            # Need to renew subscription :)
            #copilot-vim.enable = true; # GtHub Copilot
          };

          extraPlugins = with pkgs.vimPlugins; [
            vim-repeat

            # Auto completion
            #neodev-nvim
            #lsp-zero-nvim
            #nvim-lspconfig

            # Theme
            tokyonight-nvim
          ];
        };
      };
    })
  ];
}
