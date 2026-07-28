import Foundation

/// A minimal, distro-neutral shell configuration for a new box.
///
/// Two things make this necessary. Bind-mounting the persistent home over
/// `/home/<user>` hides whatever the image put there, and some distributions
/// (Alpine, notably) ship no `/etc/skel` at all — so without this you land in a
/// bare shell with no prompt, no history and no completion, which is a poor
/// first impression of a machine you're meant to live in.
public enum DefaultDotfiles {

    public static let bashrc = """
        # Written by appbox when this box was created. Yours to edit — it lives
        # on the host and survives rebuilding the box.

        # Interactive shells only.
        case $- in
            *i*) ;;
              *) return;;
        esac

        HISTSIZE=10000
        HISTFILESIZE=20000
        HISTCONTROL=ignoreboth
        shopt -s histappend 2>/dev/null
        shopt -s checkwinsize 2>/dev/null

        alias ll='ls -alF'
        alias la='ls -A'
        alias l='ls -CF'
        if ls --color=auto >/dev/null 2>&1; then
            alias ls='ls --color=auto'
            alias grep='grep --color=auto'
        fi

        # user@box:cwd$ — green user, blue path.
        PS1='\\[\\e[32m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[34m\\]\\w\\[\\e[0m\\]\\$ '

        for completion in /etc/bash_completion /usr/share/bash-completion/bash_completion; do
            [ -r "$completion" ] && . "$completion" && break
        done

        [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"

        """

    public static let profile = """
        # Written by appbox. Login shells read this; it defers to .bashrc.
        if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
            . "$HOME/.bashrc"
        fi

        [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
        export PATH

        """

    /// Files written into an otherwise-empty home, by name.
    public static var files: [String: String] {
        [".bashrc": bashrc, ".profile": profile]
    }
}
