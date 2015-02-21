# maintains a jump-list of the directories you actually use
#
# INSTALL:
#     * put something like this in your .bashrc/.zshrc:
#         . /path/to/s.sh
#     * cd around for a while to build up the db
#     * PROFIT!!
#     * optionally:
#         set $_S_CMD in .bashrc/.zshrc to change the command (default z).
#         set $_S_DATA in .bashrc/.zshrc to change the datafile (default ~/.z).
#         set $_S_NO_RESOLVE_SYMLINKS to prevent symlink resolution.
#         set $_S_NO_PROMPT_COMMAND if you're handling PROMPT_COMMAND yourself.
#         set $_S_EXCLUDE_DIRS to an array of directories to exclude.
#         set $_S_OWNER to your username if you want use z while sudo with $HOME kept
#
# USE:
#     * z foo     # cd to most frecent dir matching foo
#     * z foo bar # cd to most frecent dir matching foo and bar
#     * z -r foo  # cd to highest ranked dir matching foo
#     * z -t foo  # cd to most recently accessed dir matching foo
#     * z -l foo  # list matches instead of cd
#     * z -c foo  # restrict matches to subdirs of $PWD

[ -d "${_S_DATA:-$HOME/.s}" ] && {
    echo "ERROR: s.sh's datafile (${_S_DATA:-$HOME/.s}) is a directory."
}

_s() {

    local datafile="${_S_DATA:-$HOME/.s}"

    # bail if we don't own ~/.s and $_S_OWNER not set
    [ -z "$_S_OWNER" -a -f "$datafile" -a ! -O "$datafile" ] && return

    # add entries
    if [ "$1" = "--add" ]; then
        shift

        # No start with ssh isn't worth matching
        [ "${*:0:3}" != "ssh" ] && return
        echo "$*"

        # don't track excluded dirs
        local exclude
        for exclude in "${_S_EXCLUDE_DIRS[@]}"; do
            [ "$*" = "$exclude" ] && return
        done

        # maintain the data file
        local tempfile="$datafile.$RANDOM"
        while read line; do
            # only count directories
            [ -d "${line%%\|*}" ] && echo $line
        done < "$datafile" | awk -v path="$*" -v now="$(date +%s)" -F"|" '
            BEGIN {
                rank[path] = 1
                time[path] = now
            }
            $2 >= 1 {
                # drop ranks below 1
                if( $1 == path ) {
                    rank[$1] = $2 + 1
                    time[$1] = now
                } else {
                    rank[$1] = $2
                    time[$1] = $3
                }
                count += $2
            }
            END {
                if( count > 9000 ) {
                    # aging
                    for( x in rank ) print x "|" 0.99*rank[x] "|" time[x]
                } else for( x in rank ) print x "|" rank[x] "|" time[x]
            }
        ' 2>/dev/null >| "$tempfile"
        # do our best to avoid clobbering the datafile in a race condition
        if [ $? -ne 0 -a -f "$datafile" ]; then
            env rm -f "$tempfile"
        else
            [ "$_S_OWNER" ] && chown $_S_OWNER:$(id -ng $_S_OWNER) "$tempfile"
            env mv -f "$tempfile" "$datafile" || env rm -f "$tempfile"
        fi

    # tab completion
    elif [ "$1" = "--complete" -a -s "$datafile" ]; then
        while read line; do
            [ -d "${line%%\|*}" ] && echo $line
        done < "$datafile" | awk -v q="$2" -F"|" '
            BEGIN {
                if( q == tolower(q) ) imatch = 1
                q = substr(q, 3)
                gsub(" ", ".*", q)
            }
            {
                if( imatch ) {
                    if( tolower($1) ~ tolower(q) ) print $1
                } else if( $1 ~ q ) print $1
            }
        ' 2>/dev/null

    else
        # list/go
        while [ "$1" ]; do case "$1" in
            --) while [ "$1" ]; do shift; local fnd="$fnd${fnd:+ }$1";done;;
            -*) local opt=${1:1}; while [ "$opt" ]; do case ${opt:0:1} in
                    c) local fnd="^$PWD $fnd";;
                    h) echo "${_S_CMD:-s} [-chlrtx] args" >&2; return;;
                    x) sed -i -e "\:^${PWD}|.*:d" "$datafile";;
                    l) local list=1;;
                    r) local typ="rank";;
                    t) local typ="recent";;
                esac; opt=${opt:1}; done;;
             *) local fnd="$fnd${fnd:+ }$1";;
        esac; local last=$1; shift; done
        [ "$fnd" -a "$fnd" != "^$PWD " ] || local list=1

        # if we hit enter on a completion just go there
        case "$last" in
            # completions will always start with /
            /*) [ -z "$list" -a -d "$last" ] && cd "$last" && return;;
        esac

        # no file yet
        [ -f "$datafile" ] || return

        local cd
        cd="$(while read line; do
            [ -d "${line%%\|*}" ] && echo $line
        done < "$datafile" | awk -v t="$(date +%s)" -v list="$list" -v typ="$typ" -v q="$fnd" -F"|" '
            function frecent(rank, time) {
                # relate frequency and time
                dx = t - time
                if( dx < 3600 ) return rank * 4
                if( dx < 86400 ) return rank * 2
                if( dx < 604800 ) return rank / 2
                return rank / 4
            }
            function output(files, out, common) {
                # list or return the desired directory
                if( list ) {
                    cmd = "sort -n >&2"
                    for( x in files ) {
                        if( files[x] ) printf "%-10s %s\n", files[x], x | cmd
                    }
                    if( common ) {
                        printf "%-10s %s\n", "common:", common > "/dev/stderr"
                    }
                } else {
                    if( common ) out = common
                    print out
                }
            }
            function common(matches) {
                # find the common root of a list of matches, if it exists
                for( x in matches ) {
                    if( matches[x] && (!short || length(x) < length(short)) ) {
                        short = x
                    }
                }
                if( short == "/" ) return
                # use a copy to escape special characters, as we want to return
                # the original. yeah, this escaping is awful.
                clean_short = short
                gsub(/[\(\)\[\]\|]/, "\\\\&", clean_short)
                for( x in matches ) if( matches[x] && x !~ clean_short ) return
                return short
            }
            BEGIN {
                gsub(" ", ".*", q)
                hi_rank = ihi_rank = -9999999999
            }
            {
                if( typ == "rank" ) {
                    rank = $2
                } else if( typ == "recent" ) {
                    rank = $3 - t
                } else rank = frecent($2, $3)
                if( $1 ~ q ) {
                    matches[$1] = rank
                } else if( tolower($1) ~ tolower(q) ) imatches[$1] = rank
                if( matches[$1] && matches[$1] > hi_rank ) {
                    best_match = $1
                    hi_rank = matches[$1]
                } else if( imatches[$1] && imatches[$1] > ihi_rank ) {
                    ibest_match = $1
                    ihi_rank = imatches[$1]
                }
            }
            END {
                # prefer case sensitive
                if( best_match ) {
                    output(matches, best_match, common(matches))
                } else if( ibest_match ) {
                    output(imatches, ibest_match, common(imatches))
                }
            }
        ')"
        [ $? -gt 0 ] && return
        [ "$cd" ] && cd "$cd"
    fi
}

alias ${_S_CMD:-s}='_s 2>&1'

[ "$_S_NO_RESOLVE_SYMLINKS" ] || _S_RESOLVE_SYMLINKS="-P"

if compctl >/dev/null 2>&1; then
    # zsh
    [ "$_S_NO_PROMPT_COMMAND" ] || {
        # populate directory list, avoid clobbering any other precmds.
        if [ "$_S_NO_RESOLVE_SYMLINKS" ]; then
            _s_preexec() {
                _s --add $1
            }
        else
            _s_preexec() {
                _s --add $1
            }
        fi
        [[ -n "${preexec_functions[(r)_s_preexec]}" ]] || {
            preexec_functions[$(($#preexec_functions+1))]=_s_preexec
        }
    }
    _s_zsh_tab_completion() {
        # tab completion
        local compl
        read -l compl
        reply=(${(f)"$(_s --complete "$compl")"})
    }
    compctl -U -K _s_zsh_tab_completion _s
elif complete >/dev/null 2>&1; then
    # bash
    # tab completion
    complete -o filenames -C '_s --complete "$COMP_LINE"' ${_S_CMD:-s}
    [ "$_S_NO_PROMPT_COMMAND" ] || {
        # populate directory list. avoid clobbering other PROMPT_COMMANDs.
        grep "_s --add" <<< "$PROMPT_COMMAND" >/dev/null || {
            PROMPT_COMMAND="$PROMPT_COMMAND"$'\n''_s --add "$(command pwd '$_S_RESOLVE_SYMLINKS' 2>/dev/null)" 2>/dev/null;'
        }
    }
fi