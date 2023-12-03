 { lib, ...} : with lib;{ 
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
 }