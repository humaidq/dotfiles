{
  config,
  pkgs,
  vars,
  ...
}:
let
  allowedSigners = pkgs.writeText "allowed-signers" ''
    git@huma.id sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC+JivWVZLN5Q+gQp+Y+YOHr0tglTPujT5uqz0Vk//YnAAAABHNzaDo=
    humaid.alqassimi@tii.ae sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIM//VbFc8diwQ7MTRLGzKNd/Jghtd5w1o+eOJD0skwCmAAAAB3NzaDpUSUk=

    bmg.avoin@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEJ9ewKwo5FLj6zE30KnTn8+nw7aKdei9SeTwaAeRdJDAAAABHNzaDo=
    bmg.avoin@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIA/pwHnzGNM+ZU4lANGROTRe2ZHbes7cnZn72Oeun/MCAAAABHNzaDo=
  '';
in
{
  config = {
    home-manager.users.${vars.user} = {
      programs.jujutsu = {
        enable = false;
        settings = {
          user = {
            name = config.sifr.fullname;
            email = config.sifr.gitEmail;
          };

          signing = {
            sign-all = true;
            backend = "ssh";
            key = "~/.ssh/id_ed25519_sk.pub";
          };

          "--scope" = [
            {
              "--when".repositories = [ "~/repos/tii" ];
              user.email = "humaid.alqassimi@tii.ae";
              signing.key = "~/.ssh/id_ed25519_sk_tii.pub";
              signing.backends.ssh.program = "ssh -i ~/.ssh/id_ed25519_sk_tii";
            }
          ];
        };
      };

      programs.git = {
        settings = {
          gpg.format = "ssh";
          gpg.ssh.allowedSignersFile = "${allowedSigners}";
          tag.gpgSign = true;
          commit.gpgSign = true;
          sendemail = {
            smtpserver = "smtp.migadu.com";
            smtpuser = "me@huma.id";
            smtpencryption = "tls";
            smtpserverport = "587";
          };
        };
        includes = [
          {
            condition = "gitdir:~/repos/tii/";
            contents = {
              user.email = "humaid.alqassimi@tii.ae";
              user.signingkey = "~/.ssh/id_ed25519_sk_rk_TII.pub";
              core.sshCommand = "ssh -i ~/.ssh/id_ed25519_sk_rk_TII";
              commit.gpgSign = true;
            };
          }
        ];
        signing.key = "~/.ssh/id_ed25519_sk.pub";
        signing.signByDefault = true;
      };
    };
  };
}
