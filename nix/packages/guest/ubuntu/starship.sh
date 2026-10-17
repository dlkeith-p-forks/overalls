# @cc [owner:ghuntley,label:product] ubuntu-starship-interactive-only
# This sourced initializer MUST leave noninteractive and non-Bash shells
# untouched. Interactive Bash MUST initialize Starship once per shell; a nested
# Bash process MUST initialize its own hooks despite inherited STARSHIP_SHELL.
case $- in
    *i*) ;;
    *) return ;;
esac

if [ -n "${BASH_VERSION-}" ] &&
    [ "${__overalls_starship_initialized-}" != 1 ] &&
    [ -x /usr/bin/starship ]; then
    eval "$(/usr/bin/starship init bash)"
    __overalls_starship_initialized=1
fi
