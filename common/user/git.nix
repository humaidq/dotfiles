{ nixosConfig, config, pkgs, lib, ... }:
{
  config = lib.mkMerge [
    ({ # Default across all installations
      programs.git = {
        enable = true;
        package = pkgs.gitAndTools.gitFull;
        aliases = { co = "checkout"; };
        #signing.key = "";
        #signing.signByDefault = true;
        delta.enable = true;
        userName = "Humaid AlQassimi";
        userEmail = "git@huma.id";
        extraConfig = {
          core.editor = "nvim";
          pull.rebase = "true";
          init.defaultBranch = "master";
          format.signoff = true;
          commit.verbose = "yes";
          url = {
            #"git@github.com:".insteadOf = "https://github.com/";
            #"git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
          };
        };
      };
    })
    (lib.mkIf nixosConfig.hsys.workProfile {
      programs.git = {
        userEmail = "humaid@ssrc.tii.ae";
      };
    })
    (lib.mkIf nixosConfig.hsys.workProfile { # Home-profile only
      programs.git.extraConfig = {
        sendmail.smtpserver = "smtp.migadu.com";
        sendmail.smtpuser = "git@humaidq.ae";
        sendmail.smtpencryption = "tls";
        sendmail.smtpserverport = "587";
      };
    })
  ];
}
