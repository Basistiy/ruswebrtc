# Simple WebRTC signaling demo

A minimal signaling server that lets two browser peers exchange WebRTC SDP/ICE over WebSocket and establish a direct data channel.

## Run

```bash
npm install
npm start
```

This starts the signaling server on `http://localhost:8080`.

## Flutter frontend

A Flutter client is available in [`flutter_app`](./flutter_app).

1. Run the signaling server from repo root:

```bash
npm start
```

2. Run Flutter app:

```bash
cd flutter_app
flutter run
```

3. In the app:
- Set `Server URL` to your signaling server (for Android emulator use `http://10.0.2.2:8080`).
- Leave `Room ID` empty on one device to create room.
- Copy and share room id.
- Enter the room id on second device and press **Start Call**.

## Test flow

1. Person A opens the page and clicks **Start Call** once.
2. Person A gets an invite link (auto-copied) and shares it.
3. Person B opens the link and clicks **Start Call**.
4. The room creator automatically becomes caller when peer 2 joins.
5. Wait for connection and speak (mic/speaker permissions are requested during start).

## Notes

- Each room supports max two peers.
- Signaling is intentionally simple and forwards `offer`, `answer`, and `candidate` to the other peer.
- Invite links are room-based (`?room=<roomId>`).
- Flutter app uses room ids directly (no browser invite URL).

## TURN support (always on)

The client now loads TURN config from `server.js` (`/rtc-config`) and always uses that config.

Set these env vars when starting the server:

```bash
TURN_URLS=turn:YOUR_HOST:3478 TURN_USERNAME=USER TURN_CREDENTIAL=PASS npm start
```

For multiple TURN URLs:

```bash
TURN_URLS=turn:host1:3478,turns:host1:5349 TURN_USERNAME=USER TURN_CREDENTIAL=PASS npm start
```

If `TURN_URLS` is not set, server defaults to `turn:<request-host>:3478`.

### Quick coturn example (static auth)

Minimal `/etc/turnserver.conf` example:

```conf
listening-port=3478
fingerprint
lt-cred-mech
realm=webrtc.local
user=testuser:testpass
```

Then run app server with:

```bash
TURN_URLS=turn:YOUR_SERVER_PUBLIC_IP:3478 TURN_USERNAME=testuser TURN_CREDENTIAL=testpass npm start
```
