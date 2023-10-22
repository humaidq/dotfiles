{ nixosConfig, config, pkgs, lib, ... }:
{
  config = lib.mkMerge [
    (lib.mkIf nixosConfig.sifr.getDevTools {
      # Default across all installations
      programs.git = {
        enable = true;
        package = pkgs.gitAndTools.gitFull;
        aliases = { co = "checkout"; };
        #signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/iv9RWMN6D9zmEU85XkaU8fAWJreWkv3znan87uqTW";
        #signing.key = nixosConfig.sifr.git.sshkey;
        #signing.signByDefault = true;
        delta.enable = true;
        userName = "Humaid Alqasimi";
        userEmail = "git@huma.id";
        extraConfig = {
          core.editor = "nvim";
          init.defaultBranch = "master";
          format.signoff = true;
          #gpg.format = "ssh";
          #"gpg \"ssh\"".program = "/opt/1Password/op-ssh-sign";
          #commit.gpgsign = true;
          commit.verbose = "yes";
          push.default = "current";
          safe.directory = "/mnt/hgfs/*";
          url = {
            #"git@github.com:".insteadOf = "https://github.com/";
            #"git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
            "git@github.com:".insteadOf = "gh:";
            "git@git.sr.ht:".insteadOf = "srht:";
          };
        };
      };
    })
    (lib.mkIf (nixosConfig.sifr.workProfile && !nixosConfig.sifr.minimal) {
      programs.git = {
        #userEmail = "humaid.alqassimi+git@tii.ae";
        extraConfig.url."git@github.com:tiiuae/".insteadOf = "tii:";
      };
    })
    (lib.mkIf (!nixosConfig.sifr.workProfile && !nixosConfig.sifr.minimal) {
      # Home-profile only
      programs.git.extraConfig = {
        sendemail.smtpserver = "smtp.mail.me.com";
        sendemail.smtpuser = "me@huma.id";
        sendemail.smtpencryption = "tls";
        sendemail.smtpserverport = "587";
      };
    })
  ];
}
