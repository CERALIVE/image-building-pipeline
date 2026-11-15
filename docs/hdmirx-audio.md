# HDMI receiver audio profile default

The image's WirePlumber rule selects Pro Audio, including when ACP probed
HDMI-RX before a source arrived. This
publishes the capture node without requiring a manual profile command. Analog,
USB and HDMI transmitter cards keep their existing automatic policy.

This remains a draft pending an engine fix for the idle-no-source exit,
previously observed after about 66 minutes. The current pin alone does not
establish that the failure is fixed. Integration requires an identified fixed
engine version, an enforced minimum version or pin floor, and a no-source soak
of at least 3 hours with descriptor and thread counts. Also verify that capture
starts when a source arrives after a cold no-source probe, saved audio selections
survive an upgrade, and received audio/video timing is acceptable.
The image policy requires no extra daemon, polling loop or kernel change.

A capture node does not prove source audio. With this receiver kernel, a
video-only source may stream silence. Check the source's HDMI PCM audio setting
or choose another audio input. Silence is valid media and is never an amplitude
failure. No-signal errors use DV timings; missing-card errors use the audio roster.

Validation: text-level contracts cover the configured cold-probe preference,
source-present preference, card scope and installed configuration. They do not
exercise WirePlumber parsing or prove capture works. Hardware acceptance
also measures idle cost and resources, product audio startup, missing signal,
received flash/beep sync and sustained media before release.

The preference remains under `actions.update-props.priorities`, as it was in
the base configuration. This change replaces the preferred profile; it does not
repair an ignored bare priority member.

A no-signal engine start can leave cleanup pending even after a typed
`no_signal` refusal. Capture admission should reject an explicit DV-timing
no-link or no-lock verdict before starting the engine. The profile rule does
not repair that separate engine cleanup defect.
