# Reference cluster operator public SSH keys
let
  keys = {
    thurs = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMsmsLubwu6s0wkeKTsM2EIuJRKFsg2nZdRCVtQHk9LT thurs";
    admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/PhAuMI529/ah9/nY27UHo0G/UMCTsZcGhmYk+O3Lv admin@aivillage.org";
    sven = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai";
    joshua = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdWiZOD87KVYT6nbw56I6ZgMX+3sHyAyC3pvY1YNOf+ joshua";
  };
in
keys // {
  all = builtins.attrValues keys;
}
