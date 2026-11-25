import Foundation

public enum RemoteFPSScripts {
    /// Sourced by the existing transaction. Backups cover the daemon, launch
    /// job, token and marker; rollback restarts only a previously running job.
    public static let functions = #"""
    FPS_BIN="$PREFIX/usr/local/libexec/icontrol-fpsd"
    FPS_JOB="$PREFIX/Library/LaunchDaemons/com.icontrol.fpsd.plist"
    FPS_TOKEN="$STATE/fps-token"
    FPS_ACTIVE=0; FPS_WAS_RUNNING=0; FPS_HAD_MARKER=0
    fps_stop() {
      launchctl bootout system/com.icontrol.fpsd >/dev/null 2>&1 || launchctl unload "$FPS_JOB" >/dev/null 2>&1 || true
    }
    fps_start() {
      launchctl enable system/com.icontrol.fpsd >/dev/null 2>&1 || true
      launchctl bootstrap system "$FPS_JOB" >/dev/null 2>&1 || launchctl load -w "$FPS_JOB"
      launchctl kickstart -k system/com.icontrol.fpsd >/dev/null 2>&1 || true
    }
    fps_snapshot() {
      FPS_ACTIVE=1
      mkdir -p "$STAGE/fps-before"; chmod 700 "$STAGE/fps-before"
      if launchctl print system/com.icontrol.fpsd >/dev/null 2>&1; then FPS_WAS_RUNNING=1; fi
      if [ -f "$FPS_BIN" ]; then cp "$FPS_BIN" "$STAGE/fps-before/binary"; fi
      if [ -f "$FPS_JOB" ]; then cp "$FPS_JOB" "$STAGE/fps-before/job"; fi
      if [ -f "$FPS_TOKEN" ]; then cp "$FPS_TOKEN" "$STAGE/fps-before/token"; fi
      if [ -f "$STATE/fps-managed-by-icontrol" ]; then
        cp "$STATE/fps-managed-by-icontrol" "$STAGE/fps-before/marker"; FPS_HAD_MARKER=1
      fi
    }
    fps_prepare_install() {
      [ -f "$STAGE/icontrol-fpsd" ] || return 0
      [ -f "$STAGE/FPSDaemon.plist" ] && [ -f "$STAGE/fps-token" ] && [ -f "$STAGE/fps-sha256" ] || return 41
      [ "$(wc -c < "$STAGE/fps-token" | tr -d ' ')" = 64 ] || return 42
      LC_ALL=C grep -q '^[0-9a-f]\{64\}$' "$STAGE/fps-token" || return 43
      FPS_EXPECTED=$(cat "$STAGE/fps-sha256")
      if command -v sha256sum >/dev/null 2>&1; then FPS_ACTUAL=$(sha256sum "$STAGE/icontrol-fpsd"); FPS_ACTUAL=${FPS_ACTUAL%% *}
      elif command -v shasum >/dev/null 2>&1; then FPS_ACTUAL=$(shasum -a 256 "$STAGE/icontrol-fpsd"); FPS_ACTUAL=${FPS_ACTUAL%% *}
      else FPS_ACTUAL=$FPS_EXPECTED; fi
      [ "$FPS_ACTUAL" = "$FPS_EXPECTED" ] || { echo 'FPS 控制端传输校验失败。' >&2; return 44; }
      fps_snapshot
    }
    fps_prepare_restore() {
      [ -f "$STATE/fps-managed-by-icontrol" ] || return 0
      for FPS_FILE in binary job token; do
        [ -f "$STATE/fps-original/$FPS_FILE" ] || [ -f "$STATE/fps-original/$FPS_FILE.absent" ] || return 45
      done
      fps_snapshot
    }
    fps_copy_or_remove() {
      FPS_FROM=$1; FPS_TO=$2; FPS_MODE=$3
      if [ -f "$FPS_FROM" ]; then
        mkdir -p "${FPS_TO%/*}"
        cp "$FPS_FROM" "$FPS_TO.new"; chown root:wheel "$FPS_TO.new"; chmod "$FPS_MODE" "$FPS_TO.new"
        mv -f "$FPS_TO.new" "$FPS_TO"
      else rm -f "$FPS_TO"; fi
    }
    fps_rollback() {
      [ "$FPS_ACTIVE" = 1 ] || return 0
      fps_stop
      fps_copy_or_remove "$STAGE/fps-before/binary" "$FPS_BIN" 755
      fps_copy_or_remove "$STAGE/fps-before/job" "$FPS_JOB" 644
      fps_copy_or_remove "$STAGE/fps-before/token" "$FPS_TOKEN" 600
      fps_copy_or_remove "$STAGE/fps-before/marker" "$STATE/fps-managed-by-icontrol" 644
      if [ "$FPS_WAS_RUNNING" = 1 ] && [ -f "$FPS_JOB" ]; then fps_start || true; fi
    }
    fps_install() {
      [ "$FPS_ACTIVE" = 1 ] || return 0
      fps_stop
      mkdir -p "$STATE"; chown root:mobile "$STATE"; chmod 750 "$STATE"
      fps_copy_or_remove "$STAGE/icontrol-fpsd" "$FPS_BIN" 755
      fps_copy_or_remove "$STAGE/FPSDaemon.plist" "$FPS_JOB" 644
      fps_copy_or_remove "$STAGE/fps-token" "$FPS_TOKEN" 600
      fps_start
    }
    fps_commit() {
      [ "$FPS_ACTIVE" = 1 ] || return 0
      if [ "$FPS_HAD_MARKER" = 0 ]; then
        mkdir -p "$STATE/fps-original"; chmod 700 "$STATE/fps-original"
        for FPS_FILE in binary job token; do
          rm -f "$STATE/fps-original/$FPS_FILE" "$STATE/fps-original/$FPS_FILE.absent"
          if [ -f "$STAGE/fps-before/$FPS_FILE" ]; then
            cp "$STAGE/fps-before/$FPS_FILE" "$STATE/fps-original/$FPS_FILE"
          else touch "$STATE/fps-original/$FPS_FILE.absent"; fi
        done
        printf '%s\n' "$FPS_WAS_RUNNING" > "$STATE/fps-original/was-running"
      fi
      printf 'iControl FPS protocol 1\n' > "$STATE/fps-managed-by-icontrol"; chmod 644 "$STATE/fps-managed-by-icontrol"
    }
    fps_restore_original() {
      [ "$FPS_ACTIVE" = 1 ] || return 0
      fps_stop
      fps_copy_or_remove "$STATE/fps-original/binary" "$FPS_BIN" 755
      fps_copy_or_remove "$STATE/fps-original/job" "$FPS_JOB" 644
      fps_copy_or_remove "$STATE/fps-original/token" "$FPS_TOKEN" 600
      if [ "$(cat "$STATE/fps-original/was-running" 2>/dev/null || true)" = 1 ] && [ -f "$FPS_JOB" ]; then fps_start; fi
    }
    fps_restore_commit() {
      [ "$FPS_ACTIVE" = 1 ] || return 0
      rm -f "$STATE/fps-managed-by-icontrol"
    }
    """#
}
