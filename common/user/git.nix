{ nixosConfig, config, pkgs, lib, ... }:
{
  config = lib.mkMerge [
    ({
      # Default across all installations
      programs.git = {
        enable = true;
        package = pkgs.gitAndTools.gitFull;
        aliases = { co = "checkout"; };
        #signing.key = "";
        #signing.signByDefault = true;
        delta.enable = true;
        userName = "Humaid AlQassimi";
        extraConfig = {
          core.editor = "nvim";
          pull.rebase = "true";
          init.defaultBranch = "master";
          format.signoff = true;
          commit.verbose = "yes";
          url = {
            #"git@github.com:".insteadOf = "https://github.com/";
            #"git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
            "git@github.com:".insteadOf = "gh:";
            "git@git.sr.ht:".insteadOf = "srht:";
          };
        };
      };
    })
    (lib.mkIf nixosConfig.hsys.workProfile {
      programs.git = {
        userEmail = "humaid@ssrc.tii.ae";
        extraConfig.url."git@github.com:tiiuae/".insteadOf = "tii:";
      };
    })
    (lib.mkIf (!nixosConfig.hsys.workProfile) {
      # Home-profile only
      programs.git.userEmail = "git@huma.id";
      programs.git.extraConfig = {
        sendmail.smtpserver = "smtp.migadu.com";
        sendmail.smtpuser = "git@humaidq.ae";
        sendmail.smtpencryption = "tls";
        sendmail.smtpserverport = "587";
      };
    })
  ];
}