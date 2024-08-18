{
  config,
  lib,
  vars,
  pkgs,
  ...
}: let
  cfg = config.sifr.applications;
  dev = config.sifr.development.enable;

  lazygit_config = pkgs.writeText "lazygit.yaml" (lib.generators.toYAML {} {
    git.commit.signOff = true;
  });
in {
  options.sifr.applications.neovim.enable = lib.mkOption {
    description = "Enables neovim configurations";
    type = lib.types.bool;
    default = true;
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.neovim.enable {
      environment.systemPackages = lib.mkIf dev [
        pkgs.go
        pkgs.golangci-lint
        pkgs.gopls
        pkgs.alejandra
        pkgs.nixd
        pkgs.prettierd
      ];
      home-manager.users."${vars.user}" = let
        inherit (config.home-manager.users."${vars.user}".xdg) configHome;
      in {
        programs.nixvim = {
          enable = true;
          colorscheme = "tokyonight-night";
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
                #bashls.enable = dev;
                nixd = {
                  enable = dev;
                  rootDir = "require('lspconfig.util').root_pattern('flake.nix','.git')";
                };
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

            # TODO configure
            telescope = {
              enable = true;
              extensions = {
                file-browser.enable = true;
                fzf-native.enable = true;
              };
              keymaps = {
                "<leader><space>".action = "git_files";
                "<leader>/".action = "live_grep";
                "<leader>b".action = "buffers";
              };
            };

            vimtex.enable = dev;
            nix.enable = true;

            luasnip = {
              enable = dev;
              settings = {
                enable_autosnippets = dev;
                store_selection_keys = "<Tab>";
              };
              fromVscode = [
                {
                  lazyLoad = dev;
                  paths = "${pkgs.vimPlugins.friendly-snippets}";
                }
              ];
            };

            cmp = {
              enable = dev;
              settings = {
                performance = {
                  max_view_entires = 80; # default: 200
                };
                sources = [
                  {name = "nvim_lsp";}
                  {name = "emoji";}
                  {name = "buffer";}
                  {name = "path";}
                  {name = "luasnip";}
                ];
                snippet = {expand = "luasnip";};
                mapping = {
                  "<C-b>" = "cmp.mapping.scroll_docs(-4)";
                  "<C-f>" = "cmp.mapping.scroll_docs(4)";
                  "<C-Space>" = "cmp.mapping.complete()";
                  "<C-e>" = "cmp.mapping.abort()";
                  "<CR>" = "cmp.mapping.confirm({ select = true })";
                  "<Tab>" = "cmp.mapping(cmp.mapping.select_next_item(), {'i', 's'})";
                  "<C-j>" = "cmp.mapping.select_next_item()";
                  "<C-k>" = "cmp.mapping.select_prev_item()";
                };
              };
            };
            cmp-nvim-lsp.enable = dev;
            cmp-buffer.enable = dev;
            cmp-path.enable = dev;
            cmp_luasnip.enable = dev;
            cmp-emoji.enable = dev;
            lspkind.enable = dev;
            git-worktree = {
              enable = dev;
              enableTelescope = dev;
            };

            conform-nvim = {
              enable = dev;
              formatOnSave = {
                lspFallback = true;
                timeoutMs = 500;
              };
              notifyOnError = true;
              formattersByFt = {
                html = [["prettierd" "prettier"]];
                css = [["prettierd" "prettier"]];
                javascript = [["prettierd" "prettier"]];
                javascriptreact = [["prettierd" "prettier"]];
                typescript = [["prettierd" "prettier"]];
                typescriptreact = [["prettierd" "prettier"]];
                python = ["black"];
                nix = ["nixfmt"];
                markdown = [["prettierd" "prettier"]];
                yaml = ["yamllint" "yamlfmt"];
              };
            };
            lazygit = {
              enable = dev;
              settings = {
                config_file_path = ["${lazygit_config}"];
                use_custom_config_file_path = true;
              };
            };

            gitsigns.enable = dev;
            gitlinker.enable = dev;
            trouble.enable = dev;
            comment.enable = dev;
            fidget.enable = true;
            bufferline.enable = true;
            copilot-vim.enable = dev;
          };
          keymaps = [
            {
              mode = "n";
              key = "<leader>gg";
              action = "<cmd>LazyGit<CR>";
            }
          ];

          extraPlugins = with pkgs.vimPlugins; [
            vim-repeat

            # Theme
            tokyonight-nvim
          ];
        };
      };
    })
  ];
}
