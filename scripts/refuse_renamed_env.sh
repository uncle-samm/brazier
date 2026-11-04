# Sourced (POSIX sh) by the scripts that read BRAZIER_* variables. Those
# variables were named BEACON_* until the package was renamed to brazier
# (2026-11-04). An old name is refused, never read: a stale CI or shell
# setting must stop the run, not let it go ahead with a default instead.
renamed_env=$(env | sed -n 's/^BEACON_\([A-Za-z0-9_]*\)=.*/\1/p')
if [ -n "$renamed_env" ]; then
  for renamed_name in $renamed_env; do
    echo "BEACON_$renamed_name is set, but it is no longer read: set BRAZIER_$renamed_name instead" >&2
  done
  exit 1
fi
unset renamed_env
