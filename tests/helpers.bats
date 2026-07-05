#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CLAUDES_APPS_DIR="$BATS_TEST_TMPDIR/Applications"
  mkdir -p "$CLAUDES_APPS_DIR"
  source "$REPO/lib/common.sh"
}

@test "color_to_hue resolves a known name" {
  run color_to_hue teal
  [ "$status" -eq 0 ]
  [ "$output" = "125" ]
}

@test "color_to_hue rejects a bad name" {
  run color_to_hue chartreuse
  [ "$status" -ne 0 ]
}

@test "is_legacy_instance false when no bundle exists" {
  run is_legacy_instance Z
  [ "$status" -ne 0 ]
}

@test "is_legacy_instance false for a launcher bundle (no Claude-bin)" {
  mkdir -p "$CLAUDES_APPS_DIR/Claude L.app/Contents/MacOS"
  : > "$CLAUDES_APPS_DIR/Claude L.app/Contents/MacOS/launch"
  run is_legacy_instance L
  [ "$status" -ne 0 ]
}

@test "is_legacy_instance true when Claude-bin is present" {
  mkdir -p "$CLAUDES_APPS_DIR/Claude G.app/Contents/MacOS"
  : > "$CLAUDES_APPS_DIR/Claude G.app/Contents/MacOS/Claude-bin"
  run is_legacy_instance G
  [ "$status" -eq 0 ]
}
