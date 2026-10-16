# habit-distiller (__AGENT__) — daily habit distillation
# Runs every day at __HOUR__:__MINUTE__. Installed by install.sh on Linux.
__MINUTE__ __HOUR__ * * * PATH=__PATH__ /bin/bash __RUN_SH__ --agent __AGENT__ >> __SKILL_DIR__/cron-__AGENT__.log 2>&1
