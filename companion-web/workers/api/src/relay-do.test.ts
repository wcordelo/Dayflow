import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const deviceRegistration = (deviceID: string, platform: "macos" | "windows" | "ios") => ({
  device_id: deviceID,
  public_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  signing_public_key: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
  display_name: deviceID,
  platform,
});

const envelope = (deviceID: string, eventID: string, logicalClock: number) => ({
  event_id: eventID,
  device_id: deviceID,
  logical_clock: logicalClock,
  schema_version: 1,
  key_version: 1,
  nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  ciphertext: "ZW5jcnlwdGVkLXBheWxvYWQ",
});

const key = (byte: number) => btoa(String.fromCharCode(...new Uint8Array(32).fill(byte)));

describe("AccountRelay", () => {
  it("approves the first device, keeps later devices pending, and delivers opaque events", async () => {
    const relay = env.ACCOUNT_RELAY.getByName("relay-contract");

    const first = await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(first.value.status).toBe("approved");
    expect(first.value.key_bootstrap_required).toBe(true);

    const second = await relay.registerDevice(deviceRegistration("windows-1", "windows"));
    expect(second.ok).toBe(true);
    if (!second.ok) return;
    expect(second.value.status).toBe("pending");
    expect(second.value.key_bootstrap_required).toBe(false);

    const firstRetry = await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    expect(firstRetry.ok).toBe(true);
    if (!firstRetry.ok) return;
    expect(firstRetry.value.key_bootstrap_required).toBe(true);

    const approved = await relay.approveDevice("windows-1", "mac-1", {
      key_version: 1,
      wrapped_account_key: "d3JhcHBlZC1hY2NvdW50LWtleQ",
      wrapped_by_device_id: "mac-1",
    });
    expect(approved.ok).toBe(true);

    const wrappedKey = await relay.getWrappedKey("windows-1");
    expect(wrappedKey.ok).toBe(true);
    if (!wrappedKey.ok) return;
    expect(wrappedKey.value?.wrapped_account_key).toBe("d3JhcHBlZC1hY2NvdW50LWtleQ");
    expect(wrappedKey.value?.wrapped_by_device_id).toBe("mac-1");

    const conflictingWrappedKey = await relay.approveDevice("windows-1", "mac-1", {
      key_version: 1,
      wrapped_account_key: "different-key-for-the-same-version",
      wrapped_by_device_id: "mac-1",
    });
    expect(conflictingWrappedKey.ok).toBe(false);
    if (!conflictingWrappedKey.ok) expect(conflictingWrappedKey.error).toBe("conflict");

    const rotatedApproval = await relay.approveDevice("windows-1", "mac-1", {
      key_version: 2,
      wrapped_account_key: "dmVyc2lvbi0yLWtleQ",
      wrapped_by_device_id: "mac-1",
    });
    expect(rotatedApproval.ok).toBe(true);
    const wrappedKeys = await relay.getWrappedKeys("windows-1");
    expect(wrappedKeys.ok).toBe(true);
    if (!wrappedKeys.ok) return;
    expect(wrappedKeys.value.map((value) => value.key_version)).toEqual([1, 2]);

    const pushRegistration = await relay.registerPushToken("windows-1", { token: "windows-token-1" });
    expect(pushRegistration.ok).toBe(true);
    if (!pushRegistration.ok) return;
    expect(pushRegistration.value).toEqual({
      device_id: "windows-1",
      platform: "windows",
      registered: true,
    });

    const invalidPushRegistration = await relay.registerPushToken("windows-1", { token: "bad\u0000token" });
    expect(invalidPushRegistration.ok).toBe(false);
    if (invalidPushRegistration.ok) return;
    expect(invalidPushRegistration.error).toBe("invalid_request");

    const pushed = await relay.pushEvents("mac-1", [envelope("mac-1", "event-1", 1)]);
    expect(pushed.ok).toBe(true);
    if (!pushed.ok) return;
    expect(pushed.value.accepted_event_ids).toEqual(["event-1"]);
    expect(pushed.value.notification_count).toBe(1);

    const bootstrapAfterFirstEvent = await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    expect(bootstrapAfterFirstEvent.ok).toBe(true);
    if (!bootstrapAfterFirstEvent.ok) return;
    expect(bootstrapAfterFirstEvent.value.key_bootstrap_required).toBe(false);

    const replayed = await relay.pushEvents("mac-1", [envelope("mac-1", "event-1", 1)]);
    expect(replayed.ok).toBe(true);
    if (!replayed.ok) return;
    expect(replayed.value.duplicate_event_ids).toEqual(["event-1"]);
    expect(replayed.value.notification_count).toBe(0);

    const conflictingReplay = await relay.pushEvents("mac-1", [
      { ...envelope("mac-1", "event-1", 1), ciphertext: "ZGlmZmVyZW50LWNpcGhlcnRleHQ" },
    ]);
    expect(conflictingReplay.ok).toBe(false);
    if (!conflictingReplay.ok) expect(conflictingReplay.error).toBe("conflict");

    const conflictingBatch = await relay.pushEvents("mac-1", [
      envelope("mac-1", "event-2", 2),
      { ...envelope("mac-1", "event-1", 1), nonce: "ZGlmZmVyZW50LW5vbmNlLTEyMzQ1Njc4" },
    ]);
    expect(conflictingBatch.ok).toBe(false);
    if (!conflictingBatch.ok) expect(conflictingBatch.error).toBe("conflict");

    const pulled = await relay.pullEvents("windows-1", 0, 100);
    expect(pulled.ok).toBe(true);
    if (!pulled.ok) return;
    expect(pulled.value.events).toHaveLength(1);
    expect(pulled.value.events[0]?.envelope.ciphertext).toBe("ZW5jcnlwdGVkLXBheWxvYWQ");
    expect(pulled.value.events[0]?.envelope).not.toHaveProperty("payload");
    expect(pulled.value.events[0]?.envelope).not.toHaveProperty("screenshot");

    const revoked = await relay.revokeDevice("windows-1", "mac-1");
    expect(revoked.ok).toBe(true);
    const unregisterAfterRevoke = await relay.unregisterPushToken("windows-1");
    expect(unregisterAfterRevoke.ok).toBe(false);
    if (unregisterAfterRevoke.ok) return;
    expect(unregisterAfterRevoke.error).toBe("not_approved");
    const blockedAfterRevoke = await relay.pullEvents("windows-1", 0, 100);
    expect(blockedAfterRevoke.ok).toBe(false);
    if (!blockedAfterRevoke.ok) expect(blockedAfterRevoke.error).toBe("not_approved");
  });

  it("does not allow an unapproved device to push or retrieve a wrapped key", async () => {
    const relay = env.ACCOUNT_RELAY.getByName("relay-approval-gate");
    await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    await relay.registerDevice(deviceRegistration("android-1", "windows"));

    const pushed = await relay.pushEvents("android-1", [envelope("android-1", "event-1", 1)]);
    expect(pushed.ok).toBe(false);
    if (pushed.ok) return;
    expect(pushed.error).toBe("not_approved");

    const wrappedKey = await relay.getWrappedKey("android-1");
    expect(wrappedKey.ok).toBe(false);
    if (wrappedKey.ok) return;
    expect(wrappedKey.error).toBe("not_approved");
  });

  it("allows explicit recovery admission only when no approved device remains", async () => {
    const relay = env.ACCOUNT_RELAY.getByName("relay-recovery-admission");
    await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    const revoked = await relay.revokeDevice("mac-1", "mac-1");
    expect(revoked.ok).toBe(true);

    const recovered = await relay.registerDevice({
      ...deviceRegistration("recovered-1", "ios"),
      recovery_mode: true,
    });
    expect(recovered.ok).toBe(true);
    if (!recovered.ok) return;
    expect(recovered.value.status).toBe("approved");
    expect(recovered.value.key_bootstrap_required).toBe(false);

    const ordinary = await relay.registerDevice(deviceRegistration("ordinary-1", "windows"));
    expect(ordinary.ok).toBe(true);
    if (!ordinary.ok) return;
    expect(ordinary.value.status).toBe("pending");
  });

  it("rejects explicit recovery admission while an approved device remains", async () => {
    const relay = env.ACCOUNT_RELAY.getByName("relay-recovery-approved-device");
    await relay.registerDevice(deviceRegistration("mac-1", "macos"));

    const recovered = await relay.registerDevice({
      ...deviceRegistration("recovered-1", "ios"),
      recovery_mode: true,
    });
    expect(recovered.ok).toBe(false);
    if (recovered.ok) return;
    expect(recovered.error).toBe("forbidden");
    const devices = await relay.listDevices();
    expect(devices.ok).toBe(true);
    if (!devices.ok) return;
    expect(devices.value.map((device) => device.device_id)).toEqual(["mac-1"]);
  });

  it("re-admits a previously revoked stable device ID only during recovery", async () => {
    const relay = env.ACCOUNT_RELAY.getByName("relay-revoked-device-recovery");
    await relay.registerDevice(deviceRegistration("mac-1", "macos"));
    await relay.registerDevice(deviceRegistration("windows-1", "windows"));
    await relay.approveDevice("windows-1", "mac-1", {
      key_version: 1,
      wrapped_account_key: "d3JhcHBlZC1hY2NvdW50LWtleQ",
      wrapped_by_device_id: "mac-1",
    });
    await relay.pushEvents("mac-1", [envelope("mac-1", "event-before-recovery", 1)]);

    expect((await relay.revokeDevice("windows-1", "mac-1")).ok).toBe(true);
    expect((await relay.revokeDevice("mac-1", "mac-1")).ok).toBe(true);

    const recovered = await relay.registerDevice({
      ...deviceRegistration("windows-1", "windows"),
      public_key: key(2),
      signing_public_key: key(3),
      display_name: "Restored Windows",
      recovery_mode: true,
    });
    expect(recovered.ok).toBe(true);
    if (!recovered.ok) return;
    expect(recovered.value.status).toBe("approved");
    expect(recovered.value.key_bootstrap_required).toBe(false);
    expect(recovered.value.public_key).toBe(key(2));
    expect(recovered.value.signing_public_key).toBe(key(3));

    const staleWrappedKeys = await relay.getWrappedKeys("windows-1");
    expect(staleWrappedKeys.ok).toBe(true);
    if (!staleWrappedKeys.ok) return;
    expect(staleWrappedKeys.value).toEqual([]);

    const recoveredEvents = await relay.pullEvents("windows-1", 0, 100);
    expect(recoveredEvents.ok).toBe(true);
    if (!recoveredEvents.ok) return;
    expect(recoveredEvents.value.events.map((event) => event.envelope.event_id)).toEqual([
      "event-before-recovery",
    ]);
  });
});
