{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.shell;
in
{
  options.lab.shell = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable AI Village Zsh shell configuration, prompts, and plugins.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      # Bypass the zsh-newuser-install wizard prompt for users without a custom ~/.zshrc
      interactiveShellInit = ''
        zsh-newuser-install() { :; }
      '';

      # AI Village Brand Palette: #89c4a2 (Sage Green user), #67b1d7 (Steel Blue host), #d4bd72 (Brand Gold path)
      promptInit = ''
        PROMPT='%F{#89c4a2}%n%f@%F{#67b1d7}%m%f %F{#d4bd72}%1~%f %# '
      '';

      ohMyZsh = {
        enable = true;
        theme = "minimal";
        plugins = [
          "git"
          "sudo"
        ];
      };
    };

    # Automatically seed an empty .zshrc on user activation so Zsh doesn't trigger the newuser wizard
    system.userActivationScripts.zshrc = ''
      if [ ! -f "$HOME/.zshrc" ]; then
        touch "$HOME/.zshrc"
      fi
    '';

    users.defaultUserShell = pkgs.zsh;
  };
}
