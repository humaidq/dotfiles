{lib, ...}:
with lib; {
  options.sifr.timezone = mkOption {
    description = "Sets the timezone";
    type = types.str;
    default = "Asia/Dubai";
  };
  # TODO move for git
  options.sifr.username = mkOption {
    description = "Short username of the system user";
    type = types.str;
    default = "humaid";
  };
  options.sifr.fullname = mkOption {
    description = "Full name of the system user";
    type = types.str;
    default = "Humaid Alqasimi";
  };
  options.sifr.banner = mkOption {
    description = "System use banner";
    type = types.str;
    default = ''
      You are accessing a private computer system.

      System usage may be monitored, recorded, and subject to audit.

      Unauthorised use of the system is prohibited and subject to criminal and civil penalties.

      Use of the system indicates consent to monitoring and recording.
    '';
  };
}
