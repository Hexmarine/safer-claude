# Auto-clean scanned activation URLs into bare serials (safer-ops)

## Context

Device barcodes/QR codes sometimes encode an activation URL like
`https://activation.sensorglobal.com/?s=000289307390C0012406` rather than the bare
serial. Today every serial entry point in safer-ops takes the scanned value verbatim
(camera scan via `CameraScanner.tsx`, or keyboard-wedge scanners typing straight into
the text inputs), so a URL lands in the serial field and lookups fail. We want any
URL-shaped input cleaned down to the bare serial automatically.

## Approach

Add one shared `normalizeSerial()` helper and apply it at every serial entry point:
camera-scan callbacks, the text inputs themselves (covers keyboard-wedge scanners and
paste), and as a backend Zod transform (belt and braces).

### 1. Shared helper — `packages/shared/src/index.ts`

Next to the existing serial helpers (`kitDeviceTypeFromSerial`, ~line 663):

```ts
export function normalizeSerial(input: string | null | undefined): string {
  if (!input) return "";
  const trimmed = String(input).trim();
  if (/^https?:\/\//i.test(trimmed)) {
    try {
      const url = new URL(trimmed);
      const fromQuery = url.searchParams.get("s")?.trim();
      if (fromQuery) return fromQuery;
    } catch {
      // not a parseable URL — fall through to raw value
    }
  }
  return trimmed;
}
```

- Only the `?s=` query param is extracted (matches the known activation-URL format);
  anything else passes through trimmed, so manual entry is unaffected.

### 2. Frontend integration — `apps/web/src/views/`

Apply `normalizeSerial` in:

- **`CameraScanner.tsx`** (~line 67): `onScan(normalizeSerial(value))` — cleans for all
  camera-scan consumers in one place.
- **`KitDetailPanel.tsx`**: in the serial inputs' `onChange` for both depot
  (`serialNumber`, ~line 118) and on-site (`onsiteSerial`, ~line 294) fields —
  `setX(normalizeSerial(e.target.value))`-style. This catches keyboard-wedge scanners
  and paste. (The `handleScan` at ~line 434 is then already covered by CameraScanner,
  but normalizing there too is harmless.)
- **`InstallerView.tsx`**: kit-lookup input `onChange` (`serialInput`, ~line 279) and
  submit (~line 315 `setSerial(...)`).
- **`DevicesView.tsx`**: detach-by-serial input/submit (~line 119).
- **`MqttMonitorDrawer.tsx`**: hub-serial input (~line 27).

Note: normalizing in `onChange` is safe — a typed value only matches once it's a full
`http(s)://…?s=…` string, which no one types by hand; wedge scanners emit the whole
string in one burst so the field snaps to the bare serial.

### 3. Backend safety net — Zod transforms

Change `z.string().trim().min(1).max(120)` to add `.transform(normalizeSerial)` (or use
`z.string().max(255).transform(normalizeSerial).pipe(z.string().min(1).max(120))` so a
long URL isn't rejected before transform) in:

- `apps/api/src/kit-routes.ts` ~line 55 (`serialNumber`)
- `apps/api/src/routes.ts` ~line 95 (`serialNumber`)
- `apps/api/src/mqtt-monitor-routes.ts` ~line 10 (`serial`)

Import `normalizeSerial` from the shared package (API already depends on it).

### 4. Tests

Add unit tests for `normalizeSerial` in the shared package's existing test setup:
bare serial passthrough, activation URL → serial, URL without `?s=` → raw trimmed,
whitespace, empty/null.

## Verification

- `pnpm test` in the repo (shared-package unit tests).
- Run the web app, open a kit's add-device field, paste
  `https://activation.sensorglobal.com/?s=000289307390C0012406` — field should show
  `000289307390C0012406`. Repeat on installer kit-lookup.
- Hit the API directly with a URL-shaped `serialNumber` to confirm the Zod transform
  cleans it.

## Traceability

Per repo rule: no new silent catches that swallow errors — the URL-parse catch only
falls back to the raw value, no logging needed (it's input normalization, not an op).
