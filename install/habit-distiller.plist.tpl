<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>__LABEL__</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__RUN_SH__</string>
        <string>--agent</string>
        <string>__AGENT__</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>__HOUR__</integer>
        <key>Minute</key>
        <integer>__MINUTE__</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>__PATH__</string>
    </dict>

    <key>StandardOutPath</key>
    <string>__SKILL_DIR__/launchd-__AGENT__.out.log</string>
    <key>StandardErrorPath</key>
    <string>__SKILL_DIR__/launchd-__AGENT__.err.log</string>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
