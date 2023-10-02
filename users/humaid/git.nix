{ nixosConfig, config, pkgs, lib, ... }:
{
  config = lib.mkMerge [
    ({
      # Default across all installations
      programs.git = {
        enable = true;
        package = pkgs.gitAndTools.gitFull;
        aliases = { co = "checkout"; };
        #signing.key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/iv9RWMN6D9zmEU85XkaU8fAWJreWkv3znan87uqTW";
        #signing.key = nixosConfig.hsys.git.sshkey;
        #signing.signByDefault = true;
        delta.enable = true;
        userName = "Humaid Alqasimi";
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
    (lib.mkIf nixosConfig.hsys.workProfile {
      programs.git = {
        #userEmail = "humaid.alqassimi+git@tii.ae";
		userEmail = "git@huma.id";
        extraConfig.url."git@github.com:tiiuae/".insteadOf = "tii:";
      };
    })
    (lib.mkIf (!nixosConfig.hsys.workProfile) {
      # Home-profile only
      programs.git.extraConfig = {
        sendmail.smtpserver = "smtp.migadu.com";
        sendmail.smtpuser = "git@humaidq.ae";
        sendmail.smtpencryption = "tls";
        sendmail.smtpserverport = "587";
      };
    })
  ];
}
