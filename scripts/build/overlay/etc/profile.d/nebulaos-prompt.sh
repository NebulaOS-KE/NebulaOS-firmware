# Interactive shell prompt (Run 23, Tim): user, host name and directory, so an
# SSH session says which printer it is on - "root@nebulaos-9e4f:~# " instead
# of Buildroot's bare "# ". \h follows a live host name change. BusyBox ash,
# FEATURE_EDITING_FANCY_PROMPT.
if [ -n "${PS1:-}" ]; then
	if [ "$(id -u)" -eq 0 ]; then
		PS1='\u@\h:\w# '
	else
		PS1='\u@\h:\w$ '
	fi
	export PS1
fi
