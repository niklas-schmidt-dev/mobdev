// The iPhones and iPads a Mac reports to its relay. The Mac sends a text frame
//   {"type":"devices","devices":[{"id","name","model","model_name","os_version","device_class",
//                                 "screen","bluetooth","ready"}]}
// right after connecting and whenever its devices change (RelayClient.swift). Both relays
// (this one and relay/relay.go) validate it the same way: at most 32 devices are kept, strings
// are cut to 100 characters, unknown fields are dropped, and the whole frame is ignored when it
// is larger than 16 KB or malformed (not JSON, no `devices` array, an entry without an `id`, or
// a field of the wrong type).

export interface Device {
  id: string;
  name: string;
  model: string;
  model_name: string;
  os_version: string;
  device_class: string;
  /** The Mac has the device's picture over USB. */
  screen: boolean;
  /** The Mac's Bluetooth keyboard and mouse are connected to it. */
  bluetooth: boolean;
  ready: boolean;
}

/** One Mac and its devices, as listed by /v1/account/devices and /v1/relay/devices. */
export interface MacDevices {
  name: string;
  online: boolean;
  connected_at: number | null;
  disconnected_at: number | null;
  devices: Device[];
}

export const MAX_DEVICES = 32;
export const MAX_DEVICE_STRING = 100;
export const MAX_DEVICES_FRAME_BYTES = 16 * 1024;

const encoder = new TextEncoder();

/** A missing or null string is empty; anything but a string makes the frame malformed. */
function text(value: unknown): string | null {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") return null;
  return value.length > MAX_DEVICE_STRING ? Array.from(value).slice(0, MAX_DEVICE_STRING).join("") : value;
}

function flag(value: unknown): boolean | null {
  if (value === undefined || value === null) return false;
  return typeof value === "boolean" ? value : null;
}

/** Validates a device list. Returns null if it is malformed. */
export function sanitizeDevices(value: unknown): Device[] | null {
  if (!Array.isArray(value)) return null;
  const devices: Device[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) return null;
    const raw = entry as Record<string, unknown>;
    const device = {
      id: text(raw.id),
      name: text(raw.name),
      model: text(raw.model),
      model_name: text(raw.model_name),
      os_version: text(raw.os_version),
      device_class: text(raw.device_class),
      screen: flag(raw.screen),
      bluetooth: flag(raw.bluetooth),
      ready: flag(raw.ready),
    };
    if (!device.id || Object.values(device).some((field) => field === null)) return null;
    devices.push(device as Device);
  }
  return devices.slice(0, MAX_DEVICES);
}

/** The devices in a parsed "devices" frame, or null if the frame is too large or malformed. */
export function devicesFromFrame(message: string, frame: { devices?: unknown }): Device[] | null {
  if (message.length > MAX_DEVICES_FRAME_BYTES || encoder.encode(message).byteLength > MAX_DEVICES_FRAME_BYTES) {
    return null;
  }
  return sanitizeDevices(frame.devices);
}

/** Reads a list stored by the relay. */
export function parseStoredDevices(json: string | null): Device[] {
  if (!json) return [];
  try {
    return sanitizeDevices(JSON.parse(json)) ?? [];
  } catch {
    return [];
  }
}
