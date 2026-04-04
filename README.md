# Simple WebRTC signaling demo

A minimal signaling server that lets two browser peers exchange WebRTC SDP/ICE over WebSocket and establish a direct data channel.

## Run

```bash
npm install
npm start
```

Then open [http://localhost:8080](http://localhost:8080) in two browser windows/tabs.

## Test flow

1. In both tabs, click **Connect Signaling**.
2. In one tab, click **Start as Caller**.
3. Wait for the data channel to open in both tabs.
4. Send messages between tabs.

## Notes

- This demo keeps one room with max two peers.
- Signaling is intentionally simple and forwards `offer`, `answer`, and `candidate` to the other peer.

## TURN support

The client always includes Google STUN. To add TURN, pass credentials in the page URL:

```text
http://192.168.1.112:8080/?turnUrls=turn:YOUR_TURN_HOST:3478&turnUsername=USER&turnCredential=PASS
```

For multiple TURN URLs, separate with commas:

```text
?turnUrls=turn:host1:3478,turns:host1:5349
```

Both peers should open the page with the same TURN parameters.

### Quick coturn example (static auth)

Minimal `/etc/turnserver.conf` example:

```conf
listening-port=3478
fingerprint
lt-cred-mech
realm=webrtc.local
user=testuser:testpass
```

Then run coturn and use:

```text
?turnUrls=turn:YOUR_SERVER_PUBLIC_IP:3478&turnUsername=testuser&turnCredential=testpass
```
