/*
 * WebSocket relay - a generic broadcast relay, dependency free (JDK only).
 *
 * One room per url path: every frame a client sends is forwarded to the other
 * members of its room. Any WebSocket client can use it: no registration, no
 * state on disk, no handshake beyond the standard one.
 *
 * Control frames the relay itself sends to a member:
 *
 *   {"type":"join","uid":"000001","alias":"peer","total":2,"self":true}
 *   {"type":"join","uid":"000001","alias":"peer","total":2}
 *   {"type":"leave","uid":"000001","alias":"peer","total":1}
 *
 * and every forwarded frame is wrapped as:
 *
 *   {"uid":"000001","alias":"peer","message":"<the exact frame the peer sent>"}
 *
 * A sender never gets its own frame back, so no client has to filter its echo.
 *
 * Build (JDK 11+, one jar for every platform):
 *   javac --release 11 -encoding UTF-8 -d build ws-relay.java
 *   jar --create --file ws-relay.jar --main-class WsRelay -C build .
 *
 * Run:
 *   java -jar ws-relay.jar --port 8765      (also: -P 8765 / --port=8765)
 *   clients connect to ws://<host>:8765/c/<room> - the last path segment is the
 *   room, /c/ is only a convention, any prefix works
 *   check: java -jar ws-relay.jar --selftest
 *
 * A page opened over https may only open wss:// sockets: put a TLS reverse
 * proxy (nginx, caddy, ...) in front of this relay for that.
 */

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.TreeMap;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLException;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

// The file is named ws-relay.java (to match ws-relay.jar), so the class is not
// public: javac only forces the file name for a public top level class, and the
// launcher runs a package private main class fine (verified with java -jar).
final class WsRelay {

    static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    static final int MAX_MESSAGE = 8 * 1024 * 1024;
    static final int MAX_ROOM = 64;
    static final int HTTP_QUEUE_LIMIT = 4096;    // frames waiting for one HTTP poller
    static final long HTTP_TTL_MS = 15000;       // an HTTP client stays "present" this long
    static final int HTTP_MAX_WAIT_MS = 10000;   // long poll cap
    static final int OP_CONT = 0x0;
    static final int OP_TEXT = 0x1;
    static final int OP_BIN = 0x2;
    static final int OP_CLOSE = 0x8;
    static final int OP_PING = 0x9;
    static final int OP_PONG = 0xA;

    static final Object LOG_LOCK = new Object();
    static volatile boolean verbose = true;

    static void log(String text) {
        synchronized (LOG_LOCK) {
            System.out.println("[relay] " + text);
            System.out.flush();
        }
    }

    /** Server to client frames are never masked (RFC 6455, 5.1). */
    static byte[] frame(int opcode, byte[] payload) {
        byte[] header = new byte[10];
        int at = 0;
        header[at++] = (byte) (0x80 | opcode);
        int length = payload.length;
        if (length < 126) {
            header[at++] = (byte) length;
        } else if (length < 65536) {
            header[at++] = (byte) 126;
            header[at++] = (byte) (length >>> 8);
            header[at++] = (byte) length;
        } else {
            header[at++] = (byte) 127;
            for (int shift = 56; shift >= 0; shift -= 8) {
                header[at++] = (byte) (((long) length) >>> shift);
            }
        }
        byte[] out = new byte[at + length];
        System.arraycopy(header, 0, out, 0, at);
        System.arraycopy(payload, 0, out, at, length);
        return out;
    }

    /** Client frames must be masked (used by the self test). */
    static byte[] maskedFrame(int opcode, byte[] payload) {
        byte[] plain = frame(opcode, payload);
        int head = plain.length - payload.length;
        byte[] mask = new byte[4];
        new Random().nextBytes(mask);
        byte[] out = new byte[plain.length + 4];
        System.arraycopy(plain, 0, out, 0, head);
        out[1] = (byte) (out[1] | 0x80);
        System.arraycopy(mask, 0, out, head, 4);
        for (int i = 0; i < payload.length; i++) {
            out[head + 4 + i] = (byte) (payload[i] ^ mask[i % 4]);
        }
        return out;
    }

    static void write(Client client, byte[] blob) throws IOException {
        synchronized (client.sendLock) {
            client.out.write(blob);
            client.out.flush();
        }
    }

    static final class Frame {
        final boolean fin;
        final int opcode;
        final byte[] payload;

        Frame(boolean fin, int opcode, byte[] payload) {
            this.fin = fin;
            this.opcode = opcode;
            this.payload = payload;
        }
    }

    /**
     * Buffered socket reader: the handshake and the first frames may arrive in
     * one TCP segment, so the leftover of the head has to be kept.
     */
    static final class Reader {
        private final InputStream in;
        private byte[] buf;
        private int len;

        Reader(InputStream in, byte[] initial, int initialLen) {
            this.in = in;
            this.buf = initial;
            this.len = initialLen;
        }

        private void fill(int count) throws IOException {
            if (buf.length - len < count) {
                byte[] bigger = new byte[Math.max(len + count, len * 2 + 16)];
                System.arraycopy(buf, 0, bigger, 0, len);
                buf = bigger;
            }
            while (len < count) {
                int read = in.read(buf, len, buf.length - len);
                if (read < 0) {
                    throw new EOFException("peer closed");
                }
                len += read;
            }
        }

        byte[] read(int count) throws IOException {
            fill(count);
            byte[] out = new byte[count];
            System.arraycopy(buf, 0, out, 0, count);
            System.arraycopy(buf, count, buf, 0, len - count);
            len -= count;
            return out;
        }

        Frame readFrame() throws IOException {
            byte[] head = read(2);
            boolean fin = (head[0] & 0x80) != 0;
            int opcode = head[0] & 0x0F;
            boolean masked = (head[1] & 0x80) != 0;
            long length = head[1] & 0x7F;
            if (length == 126) {
                byte[] raw = read(2);
                length = ((raw[0] & 0xFFL) << 8) | (raw[1] & 0xFFL);
            } else if (length == 127) {
                byte[] raw = read(8);
                length = 0;
                for (int i = 0; i < 8; i++) {
                    length = (length << 8) | (raw[i] & 0xFFL);
                }
            }
            if (length > MAX_MESSAGE) {
                throw new IOException("frame of " + length + " bytes is over the "
                        + MAX_MESSAGE + " byte limit");
            }
            byte[] mask = masked ? read(4) : null;
            byte[] payload = length > 0 ? read((int) length) : new byte[0];
            if (mask != null) {
                for (int i = 0; i < payload.length; i++) {
                    payload[i] = (byte) (payload[i] ^ mask[i % 4]);
                }
            }
            return new Frame(fin, opcode, payload);
        }
    }

    /**
     * A room member: either a websocket client (sock/out set) or an HTTP client
     * (sock/out null, frames wait in its queue until the next poll).
     */
    static final class Client {
        final Socket sock;
        final OutputStream out;
        final String uid;
        final String alias;
        final String room;
        final Object sendLock = new Object();
        final ArrayDeque<String> queue = new ArrayDeque<>();
        volatile long lastSeen;

        Client(Socket sock, OutputStream out, String uid, String alias, String room) {
            this.sock = sock;
            this.out = out;
            this.uid = uid;
            this.alias = alias;
            this.room = room;
            this.lastSeen = System.currentTimeMillis();
        }

        boolean isHttp() {
            return out == null;
        }
    }

    /** Hands one frame to a member: a websocket text frame or a queued poll reply. */
    static void deliver(Client member, String frameText) {
        if (member.isHttp()) {
            synchronized (member.sendLock) {
                member.queue.addLast(frameText);
                while (member.queue.size() > HTTP_QUEUE_LIMIT) {
                    member.queue.removeFirst();
                }
            }
            return;
        }
        try {
            synchronized (member.sendLock) {
                member.out.write(frame(OP_TEXT, frameText.getBytes(StandardCharsets.UTF_8)));
                member.out.flush();
            }
        } catch (IOException ignored) {
            // that member is going away; its own thread reports the leave
        }
    }

    static final Map<String, List<Client>> ROOMS = new HashMap<>();
    static final Object ROOMS_LOCK = new Object();
    static int uidSeq = 0;

    /** Unique inside this relay process; the page uses it to drop its own echo. */
    static String newUid() {
        synchronized (ROOMS_LOCK) {
            uidSeq += 1;
            return String.format("%06x", uidSeq);
        }
    }

    /** Adds the client and returns the peers that were already in the room. */
    static List<Client> join(Client client) {
        synchronized (ROOMS_LOCK) {
            List<Client> members = ROOMS.get(client.room);
            if (members == null) {
                members = new ArrayList<>();
                ROOMS.put(client.room, members);
            }
            List<Client> before = new ArrayList<>(members);
            members.add(client);
            return before;
        }
    }

    /** Removes the client and returns the peers that are left. */
    static List<Client> leave(Client client) {
        synchronized (ROOMS_LOCK) {
            List<Client> members = ROOMS.get(client.room);
            if (members == null) {
                return new ArrayList<>();
            }
            members.remove(client);
            if (members.isEmpty()) {
                ROOMS.remove(client.room);
            }
            return new ArrayList<>(members);
        }
    }

    static List<Client> others(Client client) {
        synchronized (ROOMS_LOCK) {
            List<Client> members = ROOMS.get(client.room);
            if (members == null) {
                return new ArrayList<>();
            }
            List<Client> out = new ArrayList<>(members.size());
            for (Client member : members) {
                if (member != client) {
                    out.add(member);
                }
            }
            return out;
        }
    }

    static Map<String, Integer> roomSummary() {
        synchronized (ROOMS_LOCK) {
            Map<String, Integer> out = new TreeMap<>();
            for (Map.Entry<String, List<Client>> entry : ROOMS.entrySet()) {
                out.put(entry.getKey(), entry.getValue().size());
            }
            return out;
        }
    }

    /** The room is the last path segment: /c/<room>, /<room> and ?room= all work. */
    static String roomOf(String path) {
        String clean = path;
        int mark = clean.indexOf('?');
        if (mark >= 0) {
            clean = clean.substring(0, mark);
        }
        String room = "";
        for (String part : clean.split("/")) {
            if (!part.isEmpty()) {
                room = part;
            }
        }
        if (room.length() > MAX_ROOM) {
            return "";
        }
        for (int i = 0; i < room.length(); i++) {
            char c = room.charAt(i);
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '"' || c == '\\') {
                return "";
            }
        }
        return room;
    }

    /** A short label carried in the join/leave frames: every client is a "peer". */
    static String aliasOf(Map<String, String> headers) {
        return "peer";
    }

    static String joinJson(String uid, String alias, int total, boolean self) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"type\":\"join\",\"uid\":\"").append(uid).append("\",\"alias\":\"")
            .append(alias).append("\",\"total\":").append(total);
        if (self) {
            sb.append(",\"self\":true");
        }
        return sb.append('}').toString();
    }

    static String leaveJson(String uid, String alias, int total) {
        return "{\"type\":\"leave\",\"uid\":\"" + uid + "\",\"alias\":\"" + alias
                + "\",\"total\":" + total + "}";
    }

    static void escapeJson(StringBuilder sb, String text) {
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '"' || c == '\\') {
                sb.append('\\').append(c);
            } else if (c == '\n') {
                sb.append("\\n");
            } else if (c == '\r') {
                sb.append("\\r");
            } else if (c == '\t') {
                sb.append("\\t");
            } else if (c < 0x20) {
                sb.append(String.format("\\u%04x", (int) c));
            } else {
                sb.append(c);
            }
        }
    }

    static String wrapMessage(String uid, String alias, String text) {
        StringBuilder sb = new StringBuilder(text.length() + 64);
        sb.append("{\"uid\":\"").append(uid).append("\",\"alias\":\"").append(alias)
            .append("\",\"message\":\"");
        escapeJson(sb, text);
        sb.append("\"}");
        return sb.toString();
    }

    /** Sec-WebSocket-Accept = base64(sha1(key + GUID)). */
    static String acceptKey(String key) throws IOException {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-1");
            byte[] hash = digest.digest((key + GUID).getBytes(StandardCharsets.US_ASCII));
            return Base64.getEncoder().encodeToString(hash);
        } catch (Exception err) {
            throw new IOException("SHA-1 unavailable: " + err.getMessage(), err);
        }
    }

    static void closeQuietly(Socket sock) {
        try {
            sock.close();
        } catch (IOException ignored) {
            // already gone
        }
    }

    static boolean headerContains(Map<String, String> headers, String name, String needle) {
        String value = headers.get(name);
        return value != null && value.toLowerCase().contains(needle);
    }

    static String escapeHtml(String text) {
        StringBuilder sb = new StringBuilder(text.length() + 16);
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '&') {
                sb.append("&amp;");
            } else if (c == '<') {
                sb.append("&lt;");
            } else if (c == '>') {
                sb.append("&gt;");
            } else if (c == '"') {
                sb.append("&quot;");
            } else if (c == '\'') {
                sb.append("&#39;");
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    /** A parsed request head plus whatever the client sent after it. */
    static final class Head {
        final String method;
        final String path;
        final Map<String, String> headers;
        final byte[] leftover;
        final int leftoverLen;

        Head(String method, String path, Map<String, String> headers, byte[] leftover, int leftoverLen) {
            this.method = method;
            this.path = path;
            this.headers = headers;
            this.leftover = leftover;
            this.leftoverLen = leftoverLen;
        }
    }

    static int indexOfHeadEnd(byte[] buf, int len) {
        for (int i = 0; i + 3 < len; i++) {
            if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n') {
                return i;
            }
        }
        return -1;
    }

    static Head readHead(InputStream in) throws IOException {
        byte[] buf = new byte[1024];
        int len = 0;
        int end = -1;
        while (end < 0) {
            if (len == buf.length) {
                if (buf.length >= 65536) {
                    return null;
                }
                byte[] bigger = new byte[buf.length * 2];
                System.arraycopy(buf, 0, bigger, 0, len);
                buf = bigger;
            }
            int read = in.read(buf, len, buf.length - len);
            if (read < 0) {
                return null;
            }
            len += read;
            end = indexOfHeadEnd(buf, len);
        }
        String head = new String(buf, 0, end, StandardCharsets.ISO_8859_1);
        String[] lines = head.split("\r\n");
        String[] parts = lines[0].split(" ");
        String method = parts.length > 0 ? parts[0] : "";
        String path = parts.length > 1 ? parts[1] : "/";
        Map<String, String> headers = new HashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon < 0) {
                continue;
            }
            headers.put(lines[i].substring(0, colon).trim().toLowerCase(),
                    lines[i].substring(colon + 1).trim());
        }
        int body = end + 4;
        int leftoverLen = len - body;
        byte[] leftover = new byte[Math.max(leftoverLen, 1)];
        System.arraycopy(buf, body, leftover, 0, leftoverLen);
        return new Head(method, path, headers, leftover, leftoverLen);
    }

    /** One connection: handshake, join, forward, leave. */
    static final class Handler implements Runnable {
        private final Socket sock;
        private Client client;

        Handler(Socket sock) {
            this.sock = sock;
        }

        @Override
        public void run() {
            try {
                serve();
            } catch (SSLException err) {
                log("TLS handshake failed: " + err.getMessage()
                        + " (a self signed certificate has to be accepted once in the browser)");
            } catch (IOException err) {
                if (verbose) {
                    log((client == null ? "connection" : client.uid) + " ended: " + err.getMessage());
                }
            } finally {
                closeQuietly(sock);
            }
        }

        private void serve() throws IOException {
            sock.setTcpNoDelay(true);
            InputStream in = sock.getInputStream();
            Head head = readHead(in);
            if (head == null) {
                return;
            }
            if (!"GET".equals(head.method) || !head.headers.containsKey("sec-websocket-key")
                    || !headerContains(head.headers, "upgrade", "websocket")) {
                serveHttp(head);
                return;
            }
            String room = roomOf(head.path);
            if (room.isEmpty()) {
                sendHtml("404 Not Found", "<p>the relay needs a room: /c/&lt;room&gt;</p>");
                return;
            }
            OutputStream out = sock.getOutputStream();
            String reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                    + "Connection: Upgrade\r\nSec-WebSocket-Accept: "
                    + acceptKey(head.headers.get("sec-websocket-key")) + "\r\n\r\n";
            out.write(reply.getBytes(StandardCharsets.US_ASCII));
            out.flush();

            client = new Client(sock, out, newUid(), aliasOf(head.headers), room);
            List<Client> before = join(client);
            int total = before.size() + 1;
            log(client.uid + " (" + client.alias + ") joined room " + room + " - " + total + " client(s)");
            try {
                deliver(client, joinJson(client.uid, client.alias, total, true));
                for (Client peer : before) {
                    deliver(peer, joinJson(client.uid, client.alias, total, false));
                }
                pump(new Reader(in, head.leftover, head.leftoverLen));
            } finally {
                List<Client> remaining = leave(client);
                log(client.uid + " (" + client.alias + ") left room " + room + " - "
                        + remaining.size() + " client(s)");
                for (Client peer : remaining) {
                    deliver(peer, leaveJson(client.uid, client.alias, remaining.size()));
                }
            }
        }

        /** Forward every data frame to the other room members (never back). */
        private void pump(Reader reader) throws IOException {
            byte[] buffer = null;
            while (true) {
                Frame frame = reader.readFrame();
                if (frame.opcode == OP_CLOSE) {
                    return;
                }
                if (frame.opcode == OP_PING) {
                    if (!client.isHttp()) {
                        synchronized (client.sendLock) {
                            client.out.write(frame(OP_PONG, frame.payload));
                            client.out.flush();
                        }
                    }
                    continue;
                }
                if (frame.opcode == OP_PONG) {
                    continue;
                }
                byte[] data;
                if (frame.opcode == OP_TEXT || frame.opcode == OP_BIN) {
                    if (!frame.fin) {
                        buffer = frame.payload;
                        continue;
                    }
                    data = frame.payload;
                } else if (frame.opcode == OP_CONT && buffer != null) {
                    byte[] merged = new byte[buffer.length + frame.payload.length];
                    System.arraycopy(buffer, 0, merged, 0, buffer.length);
                    System.arraycopy(frame.payload, 0, merged, buffer.length, frame.payload.length);
                    if (!frame.fin) {
                        buffer = merged;
                        continue;
                    }
                    data = merged;
                    buffer = null;
                } else {
                    continue;
                }
                String text = new String(data, StandardCharsets.UTF_8);
                List<Client> peers = others(client);
                if (verbose && text.length() > 4096) {
                    log(client.uid + " -> " + peers.size() + " peer(s), " + text.length() + " chars");
                }
                String wrapped = wrapMessage(client.uid, client.alias, text);
                for (Client peer : peers) {
                    deliver(peer, wrapped);
                }
            }
        }

        /**
         * Plain HTTP: GET polls the room (optionally long polling with &wait=ms),
         * POST publishes one frame. Both speak the same frames as the websocket
         * side, so a ws client and an http client share one room.
         */
        private void serveHttp(Head head) throws IOException {
            String room = roomOf(head.path);
            if (room.isEmpty()) {
                if ("GET".equals(head.method) || "HEAD".equals(head.method)) {
                    sendHtml("200 OK", infoPage());
                } else {
                    sendHtml("400 Bad Request", "<p>no room in the url: use /c/&lt;room&gt;</p>");
                }
                return;
            }
            Map<String, String> query = parseQuery(head.path);
            boolean publish = "POST".equals(head.method) || "PUT".equals(head.method);
            Client member = httpMember(room, query.get("uid"));
            member.lastSeen = System.currentTimeMillis();
            if (publish) {
                String body = readBody(head);
                if (body.isEmpty()) {
                    sendJson("400 Bad Request", "{\"error\":\"empty body\"}");
                    return;
                }
                List<Client> peers = others(member);
                String frame = wrapMessage(member.uid, member.alias, body);
                for (Client peer : peers) {
                    deliver(peer, frame);
                }
                if (verbose && body.length() > 4096) {
                    log(member.uid + " http POST -> " + peers.size() + " peer(s), "
                            + body.length() + " chars");
                }
                sendJson("200 OK", "{\"uid\":\"" + member.uid + "\",\"ok\":true}");
                return;
            }
            if (!"GET".equals(head.method)) {
                sendHtml("405 Method Not Allowed", "<p>GET polls, POST publishes</p>");
                return;
            }
            long wait = parseLong(query.get("wait"), 0);
            List<String> frames = drainFrames(member, wait);
            StringBuilder sb = new StringBuilder();
            sb.append("{\"uid\":\"").append(member.uid).append("\",\"frames\":[");
            for (int i = 0; i < frames.size(); i++) {
                if (i > 0) {
                    sb.append(',');
                }
                sb.append(frames.get(i));
            }
            sb.append("]}");
            sendJson("200 OK", sb.toString());
        }

        /** Reads the request body (whatever the head already carried plus the rest). */
        private String readBody(Head head) throws IOException {
            int length = (int) parseLong(head.headers.get("content-length"), 0);
            if (length <= 0) {
                return head.leftoverLen > 0
                        ? new String(head.leftover, 0, head.leftoverLen, StandardCharsets.UTF_8) : "";
            }
            if (length > 4 * 1024 * 1024) {
                throw new IOException("request body of " + length + " bytes is too large");
            }
            byte[] body = new byte[length];
            int have = Math.min(head.leftoverLen, length);
            System.arraycopy(head.leftover, 0, body, 0, have);
            InputStream in = sock.getInputStream();
            while (have < length) {
                int read = in.read(body, have, length - have);
                if (read < 0) {
                    throw new EOFException("request body cut short");
                }
                have += read;
            }
            return new String(body, 0, length, StandardCharsets.UTF_8);
        }

        private void sendJson(String status, String body) throws IOException {
            byte[] payload = body.getBytes(StandardCharsets.UTF_8);
            String head = "HTTP/1.1 " + status + "\r\n"
                    + "Content-Type: application/json; charset=utf-8\r\n"
                    + "Content-Length: " + payload.length + "\r\n"
                    + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n"
                    + "Connection: close\r\n\r\n";
            OutputStream out = sock.getOutputStream();
            out.write(head.getBytes(StandardCharsets.US_ASCII));
            out.write(payload);
            out.flush();
        }

        private String infoPage() {
            StringBuilder rows = new StringBuilder();
            for (Map.Entry<String, Integer> entry : roomSummary().entrySet()) {
                rows.append("<li>").append(escapeHtml(entry.getKey())).append(": ")
                    .append(entry.getValue()).append(" client(s)</li>");
            }
            return "<!doctype html><meta charset='utf-8'><title>WebSocket relay</title>"
                    + "<h1>WebSocket relay</h1>"
                    + "<p>Connect a websocket to <code>/c/&lt;room&gt;</code>.</p>"
                    + "<p>Rooms right now:</p><ul>"
                    + (rows.length() == 0 ? "<li>(none)</li>" : rows.toString()) + "</ul>";
        }

        private void sendHtml(String status, String body) throws IOException {
            byte[] payload = body.getBytes(StandardCharsets.UTF_8);
            String head = "HTTP/1.1 " + status + "\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: " + payload.length + "\r\nCache-Control: no-store\r\n"
                    + "Connection: close\r\n\r\n";
            OutputStream out = sock.getOutputStream();
            out.write(head.getBytes(StandardCharsets.US_ASCII));
            out.write(payload);
            out.flush();
        }
    }

    static void acceptLoop(ServerSocket server) {
        while (true) {
            Socket sock;
            try {
                sock = server.accept();
            } catch (IOException err) {
                if (server.isClosed()) {
                    return;
                }
                log("accept failed: " + err.getMessage());
                continue;
            }
            Thread thread = new Thread(new Handler(sock), "ws-relay-client");
            thread.setDaemon(true);
            thread.start();
        }
    }

    /** Finds the HTTP member with that uid (refreshing it) or creates it. */
    static Client httpMember(String room, String uid) {
        if (uid != null && !uid.isEmpty()) {
            synchronized (ROOMS_LOCK) {
                List<Client> members = ROOMS.get(room);
                if (members != null) {
                    for (Client member : members) {
                        if (member.isHttp() && member.uid.equals(uid)) {
                            member.lastSeen = System.currentTimeMillis();
                            return member;
                        }
                    }
                }
            }
        }
        Client member = new Client(null, null, newUid(), aliasOf(null), room);
        List<Client> before = join(member);
        int total = before.size() + 1;
        log(member.uid + " (http) joined room " + room + " - " + total + " client(s)");
        deliver(member, joinJson(member.uid, member.alias, total, true));
        for (Client peer : before) {
            deliver(peer, joinJson(member.uid, member.alias, total, false));
        }
        return member;
    }

    /** Takes everything queued for an HTTP member, waiting up to waitMs for a frame. */
    static List<String> drainFrames(Client member, long waitMs) {
        long deadline = System.currentTimeMillis() + Math.max(0, Math.min(waitMs, HTTP_MAX_WAIT_MS));
        List<String> out = new ArrayList<>();
        while (true) {
            synchronized (member.sendLock) {
                while (!member.queue.isEmpty()) {
                    out.add(member.queue.removeFirst());
                }
            }
            if (!out.isEmpty() || System.currentTimeMillis() >= deadline) {
                return out;
            }
            try {
                Thread.sleep(25);
            } catch (InterruptedException err) {
                Thread.currentThread().interrupt();
                return out;
            }
        }
    }

    /** Drops HTTP members that stopped polling and tells the rest of the room. */
    static void sweepHttpMembers() {
        long now = System.currentTimeMillis();
        List<Client> gone = new ArrayList<>();
        synchronized (ROOMS_LOCK) {
            for (List<Client> members : ROOMS.values()) {
                for (Client member : members) {
                    if (member.isHttp() && now - member.lastSeen > HTTP_TTL_MS) {
                        gone.add(member);
                    }
                }
            }
        }
        for (Client member : gone) {
            List<Client> remaining = leave(member);
            log(member.uid + " (http) left room " + member.room + " - "
                    + remaining.size() + " client(s)");
            for (Client peer : remaining) {
                deliver(peer, leaveJson(member.uid, member.alias, remaining.size()));
            }
        }
    }

    static void startHttpSweeper() {
        Thread thread = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException err) {
                    return;
                }
                sweepHttpMembers();
            }
        }, "ws-relay-http-sweeper");
        thread.setDaemon(true);
        thread.start();
    }

    static Map<String, String> parseQuery(String path) {
        Map<String, String> out = new HashMap<>();
        int mark = path.indexOf('?');
        if (mark < 0) {
            return out;
        }
        for (String pair : path.substring(mark + 1).split("&")) {
            if (pair.isEmpty()) {
                continue;
            }
            int equals = pair.indexOf('=');
            String name = equals < 0 ? pair : pair.substring(0, equals);
            String value = equals < 0 ? "" : pair.substring(equals + 1);
            out.put(urlDecode(name), urlDecode(value));
        }
        return out;
    }

    static String urlDecode(String text) {
        try {
            return java.net.URLDecoder.decode(text, "UTF-8");
        } catch (Exception err) {
            return text;
        }
    }

    /** Parses a port argument, warning instead of failing. */
    static int parsePortArg(String text, int current) {
        if (text == null) {
            System.err.println("[relay] missing port number (keeping " + current + ")");
            return current;
        }
        try {
            int wanted = Integer.parseInt(text.trim());
            if (wanted < 0 || wanted > 65535) {
                System.err.println("[relay] port out of range: " + text + " (keeping " + current + ")");
                return current;
            }
            return wanted;
        } catch (NumberFormatException err) {
            System.err.println("[relay] bad port: " + text + " (keeping " + current + ")");
            return current;
        }
    }

    static long parseLong(String text, long fallback) {
        if (text == null) {
            return fallback;
        }
        try {
            return Long.parseLong(text.trim());
        } catch (NumberFormatException err) {
            return fallback;
        }
    }

    /** Binds a listener: with a TLS context it speaks wss:// and https://, else ws:// and http://. */
    static ServerSocket openServer(String host, int port, SSLContext context) throws IOException {
        ServerSocket server = context == null
                ? new ServerSocket()
                : context.getServerSocketFactory().createServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(host, port));
        return server;
    }

    static void startAcceptThread(ServerSocket server, String name) {
        Thread thread = new Thread(() -> acceptLoop(server), name);
        thread.setDaemon(true);
        thread.start();
    }

    /** SSLContext from a PKCS12/JKS keystore (--tls-keystore / --tls-password). */
    static SSLContext tlsContextFromStore(String path, String password) throws IOException {
        char[] secret = password == null ? new char[0] : password.toCharArray();
        try {
            String lower = path.toLowerCase();
            String type = (lower.endsWith(".p12") || lower.endsWith(".pfx")) ? "PKCS12" : "JKS";
            KeyStore store = KeyStore.getInstance(type);
            try (InputStream in = new FileInputStream(path)) {
                store.load(in, secret);
            }
            return tlsContextOf(store, secret);
        } catch (Exception err) {
            throw new IOException("cannot load the keystore " + path + ": " + err, err);
        }
    }

    /** SSLContext from a PEM certificate chain plus a PKCS#8 private key. */
    static SSLContext tlsContextFromPem(String certPath, String keyPath) throws IOException {
        try {
            CertificateFactory factory = CertificateFactory.getInstance("X.509");
            List<Certificate> chain = new ArrayList<>();
            for (byte[] der : readPemBlocks(certPath, "CERTIFICATE")) {
                chain.add(factory.generateCertificate(new ByteArrayInputStream(der)));
            }
            if (chain.isEmpty()) {
                throw new IOException("no CERTIFICATE block in " + certPath);
            }
            List<byte[]> keys = readPemBlocks(keyPath, "PRIVATE KEY");
            if (keys.isEmpty() && !readPemBlocks(keyPath, "RSA PRIVATE KEY").isEmpty()) {
                throw new IOException(keyPath + " holds a PKCS#1 key; convert it first:"
                        + " openssl pkcs8 -topk8 -nocrypt -in key.pem -out key8.pem");
            }
            if (keys.isEmpty()) {
                throw new IOException("no PRIVATE KEY block in " + keyPath);
            }
            PrivateKey key = KeyFactory.getInstance("RSA")
                    .generatePrivate(new PKCS8EncodedKeySpec(keys.get(0)));
            KeyStore store = KeyStore.getInstance("PKCS12");
            store.load(null, null);
            store.setKeyEntry("relay", key, new char[0], chain.toArray(new Certificate[0]));
            return tlsContextOf(store, new char[0]);
        } catch (Exception err) {
            throw new IOException("cannot load the PEM pair (" + certPath + ", " + keyPath
                    + "): " + err, err);
        }
    }

    static SSLContext tlsContextOf(KeyStore store, char[] secret) throws Exception {
        KeyManagerFactory managers =
                KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        managers.init(store, secret);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(managers.getKeyManagers(), null, null);
        return context;
    }

    /** Reads every base64 block of one PEM label (CERTIFICATE, PRIVATE KEY, ...). */
    static List<byte[]> readPemBlocks(String path, String label) throws IOException {
        String text = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.US_ASCII);
        List<byte[]> out = new ArrayList<>();
        String begin = "-----BEGIN " + label + "-----";
        String end = "-----END " + label + "-----";
        int at = 0;
        while (true) {
            int start = text.indexOf(begin, at);
            if (start < 0) {
                return out;
            }
            int stop = text.indexOf(end, start);
            if (stop < 0) {
                throw new IOException("unterminated " + label + " block in " + path);
            }
            String body = text.substring(start + begin.length(), stop).replaceAll("\\s+", "");
            out.add(Base64.getDecoder().decode(body));
            at = stop + end.length();
        }
    }

    /** Minimal RFC 6455 client, used by --selftest. */
    static final class TestClient {
        final Socket sock;
        final Reader reader;

        TestClient(int port, String room, String agent, SSLSocketFactory factory) throws IOException {
            sock = factory == null ? new Socket() : factory.createSocket();
            sock.connect(new InetSocketAddress("127.0.0.1", port), 5000);
            sock.setSoTimeout(5000);
            sock.setTcpNoDelay(true);
            String key = Base64.getEncoder().encodeToString(randomBytes(16));
            String request = "GET /c/" + room + " HTTP/1.1\r\nHost: 127.0.0.1:" + port
                    + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key
                    + "\r\nUser-Agent: " + agent + "\r\n\r\n";
            OutputStream out = sock.getOutputStream();
            out.write(request.getBytes(StandardCharsets.US_ASCII));
            out.flush();
            InputStream in = sock.getInputStream();
            java.io.ByteArrayOutputStream headBuf = new java.io.ByteArrayOutputStream();
            while (true) {
                byte[] one = new byte[1];
                int read = in.read(one);
                if (read < 0) {
                    throw new IOException("relay closed during the handshake");
                }
                headBuf.write(one[0]);
                String sofar = new String(headBuf.toByteArray(), StandardCharsets.ISO_8859_1);
                if (sofar.endsWith("\r\n\r\n")) {
                    if (!sofar.startsWith("HTTP/1.1 101")) {
                        throw new IOException("handshake failed: " + sofar.split("\r\n")[0]);
                    }
                    break;
                }
                if (sofar.length() > 8192) {
                    throw new IOException("handshake head is too long");
                }
            }
            reader = new Reader(in, new byte[1], 0);
        }

        void sendText(String text) throws IOException {
            OutputStream out = sock.getOutputStream();
            out.write(maskedFrame(OP_TEXT, text.getBytes(StandardCharsets.UTF_8)));
            out.flush();
        }

        String readJson() throws IOException {
            Frame frame = reader.readFrame();
            return new String(frame.payload, StandardCharsets.UTF_8);
        }

        void close() {
            closeQuietly(sock);
        }
    }

    static byte[] randomBytes(int count) {
        byte[] out = new byte[count];
        new Random().nextBytes(out);
        return out;
    }

    static void check(boolean ok, String message) {
        if (!ok) {
            throw new IllegalStateException(message);
        }
    }

    /** Pulls the value of a "key" (string) field out of a small json frame. */
    static String extract(String json, String marker) {
        int at = json.indexOf(marker);
        if (at < 0) {
            return "";
        }
        int start = at + marker.length();
        int end = json.indexOf('"', start);
        return end < 0 ? "" : json.substring(start, end);
    }

    /** A trust-all context, used only by the self test against our own certificate. */
    static SSLContext trustAllContext() throws Exception {
        TrustManager[] managers = new TrustManager[] { new X509TrustManager() {
            @Override
            public void checkClientTrusted(java.security.cert.X509Certificate[] chain, String authType) {
            }

            @Override
            public void checkServerTrusted(java.security.cert.X509Certificate[] chain, String authType) {
            }

            @Override
            public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                return new java.security.cert.X509Certificate[0];
            }
        } };
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, managers, null);
        return context;
    }

    /** One raw HTTP request against the relay; returns the response body. */
    static String httpRequest(int port, String method, String path, String body) throws IOException {
        Socket sock = new Socket();
        sock.connect(new InetSocketAddress("127.0.0.1", port), 5000);
        sock.setSoTimeout(20000);
        OutputStream out = sock.getOutputStream();
        byte[] payload = body == null ? new byte[0] : body.getBytes(StandardCharsets.UTF_8);
        String head = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + port
                + "\r\nContent-Length: " + payload.length + "\r\nConnection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.US_ASCII));
        out.write(payload);
        out.flush();
        Reader reader = new Reader(sock.getInputStream(), new byte[1], 0);
        ByteArrayOutputStream headBuf = new ByteArrayOutputStream();
        while (true) {
            byte[] one = reader.read(1);
            headBuf.write(one[0]);
            if (new String(headBuf.toByteArray(), StandardCharsets.ISO_8859_1).endsWith("\r\n\r\n")) {
                break;
            }
            if (headBuf.size() > 16384) {
                throw new IOException("http response head is too long");
            }
        }
        String headText = new String(headBuf.toByteArray(), StandardCharsets.ISO_8859_1);
        int length = 0;
        for (String line : headText.split("\r\n")) {
            int colon = line.indexOf(':');
            if (colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase("content-length")) {
                length = (int) parseLong(line.substring(colon + 1), 0);
            }
        }
        byte[] bodyBytes = length > 0 ? reader.read(length) : new byte[0];
        sock.close();
        return new String(bodyBytes, StandardCharsets.UTF_8);
    }

    /** HTTP side of the self test: poll, publish, and ws<->http bridging. */
    static void checkHttp(int port) throws IOException {
        String first = httpRequest(port, "GET", "/c/httptest?wait=0", null);
        check(first.contains("\"type\":\"join\"") && first.contains("\"self\":true"),
                "the first HTTP poll did not return its own join: " + first);
        String uidA = extract(first, "\"uid\":\"");
        check(!uidA.isEmpty(), "the HTTP poll did not hand out a uid: " + first);

        String second = httpRequest(port, "GET", "/c/httptest?wait=0", null);
        String uidB = extract(second, "\"uid\":\"");
        check(!uidB.isEmpty() && !uidB.equals(uidA),
                "the second HTTP client did not get its own uid: " + second);

        String seen = httpRequest(port, "GET", "/c/httptest?uid=" + uidA + "&wait=0", null);
        check(seen.contains(uidB), "the first HTTP client was not told about the second: " + seen);

        String published = httpRequest(port, "POST", "/c/httptest?uid=" + uidB, "{\"action\":\"ping\"}");
        check(published.contains("\"ok\":true"), "the HTTP publish was not accepted: " + published);

        String forwarded = httpRequest(port, "GET", "/c/httptest?uid=" + uidA + "&wait=1000", null);
        String expected = "{\"uid\":\"" + uidB + "\",\"alias\":\"peer\",\"message\":"
                + "\"{\\\"action\\\":\\\"ping\\\"}\"}";
        check(forwarded.contains(expected), "the HTTP client did not get the published frame: " + forwarded);

        String ownEcho = httpRequest(port, "GET", "/c/httptest?uid=" + uidB + "&wait=0", null);
        check(!ownEcho.contains("\\\"action\\\""), "the HTTP publisher got its own frame back: " + ownEcho);

        TestClient web = new TestClient(port, "httptest", "ws-relay-selftest", null);
        String webJoin = web.readJson();
        String uidW = extract(webJoin, "\"uid\":\"");
        check(!uidW.isEmpty(), "the websocket client got no uid: " + webJoin);
        String afterJoin = httpRequest(port, "GET", "/c/httptest?uid=" + uidA + "&wait=1000", null);
        check(afterJoin.contains(uidW),
                "the HTTP client did not see the websocket client join: " + afterJoin);

        web.sendText("hello-from-ws");
        String bridged = httpRequest(port, "GET", "/c/httptest?uid=" + uidA + "&wait=1000", null);
        check(bridged.contains("hello-from-ws"),
                "the websocket frame did not reach the HTTP client: " + bridged);

        httpRequest(port, "POST", "/c/httptest?uid=" + uidA, "to-ws");
        String wsGot = web.readJson();
        check(wsGot.contains("to-ws"), "the HTTP publish did not reach the websocket client: " + wsGot);

        web.close();
        System.out.println("selftest OK: http poll/publish and ws<->http bridging");
    }

    /** Two real sockets against a real server socket: join, forward, leave. */
    static int runSelftest(SSLContext tls) throws Exception {
        ServerSocket server = tls == null
                ? new ServerSocket()
                : tls.getServerSocketFactory().createServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress("127.0.0.1", 0));
        int port = server.getLocalPort();
        SSLSocketFactory clientFactory = tls == null ? null : trustAllContext().getSocketFactory();
        verbose = false;
        Thread loop = new Thread(() -> acceptLoop(server), "ws-relay-accept");
        loop.setDaemon(true);
        loop.start();

        TestClient first = null;
        TestClient second = null;
        try {
            first = new TestClient(port, "selftest", "ws-relay-selftest", clientFactory);
            String joinA = first.readJson();
            check(joinA.contains("\"type\":\"join\""), "the first frame is not a join: " + joinA);
            check(joinA.contains("\"self\":true"), "the first join is not marked self: " + joinA);
            check(joinA.contains("\"total\":1"), "wrong total on the first join: " + joinA);
            check(joinA.contains("\"alias\":\"peer\""), "wrong alias: " + joinA);
            String uidA = extract(joinA, "\"uid\":\"");

            second = new TestClient(port, "selftest", "ws-relay-selftest", clientFactory);
            String joinB = second.readJson();
            check(joinB.contains("\"type\":\"join\""), "the second frame is not a join: " + joinB);
            check(joinB.contains("\"self\":true"), "the second join is not marked self: " + joinB);
            check(joinB.contains("\"total\":2"), "wrong total on the second join: " + joinB);
            String uidB = extract(joinB, "\"uid\":\"");

            String seen = first.readJson();
            check(seen.contains("\"type\":\"join\""), "the first client was not told: " + seen);
            check(!seen.contains("\"self\":true"), "a peer join must not be marked self: " + seen);
            check(seen.contains(uidB), "the peer join names the wrong uid: " + seen);

            first.sendText("{\"action\":\"ping\",\"id\":1}");
            String forwarded = second.readJson();
            String expected = "{\"uid\":\"" + uidA + "\",\"alias\":\"peer\",\"message\":"
                    + "\"{\\\"action\\\":\\\"ping\\\",\\\"id\\\":1}\"}";
            check(forwarded.equals(expected), "the forwarded frame is wrong: " + forwarded);

            first.sock.setSoTimeout(400);
            boolean echoed = false;
            try {
                first.readJson();
                echoed = true;
            } catch (java.net.SocketTimeoutException expectedTimeout) {
                echoed = false;
            }
            check(!echoed, "the sender got its own frame back");
            first.sock.setSoTimeout(5000);

            if (tls == null) {
                checkHttp(port);
            } else {
                System.out.println("selftest: TLS listener - the plain http checks are skipped");
            }

            StringBuilder builder = new StringBuilder(120000);
            for (int i = 0; i < 120000; i++) {
                builder.append('x');
            }
            String big = builder.toString();
            first.sendText(big);
            String bigForwarded = second.readJson();
            check(bigForwarded.contains(big), "a large frame was not forwarded intact");

            second.close();
            second = null;
            String left = first.readJson();
            check(left.contains("\"type\":\"leave\""), "no leave frame: " + left);
            check(left.contains(uidB), "the leave names the wrong uid: " + left);
            check(left.contains("\"total\":1"), "wrong total on the leave: " + left);
            System.out.println("selftest OK: join / forward (no echo) / leave"
                    + (tls == null ? "" : " (over TLS)"));
            return 0;
        } catch (Throwable err) {
            System.out.println("selftest FAILED: " + err);
            return 1;
        } finally {
            if (first != null) {
                first.close();
            }
            if (second != null) {
                second.close();
            }
            server.close();
        }
    }

    static void printUsage() {
        System.out.println("usage: java -jar ws-relay.jar [options]");
        System.out.println("  --host H, --host=H   interface to listen on (default 0.0.0.0)");
        System.out.println("  --port N, -P N       plain listener: ws:// and http:// (default 8765,");
        System.out.println("                       0 = pick a free port); --port=N and -P=N work too");
        System.out.println("  --tls-port N         extra TLS listener: wss:// and https://");
        System.out.println("  --tls-keystore F     PKCS12/JKS keystore holding the server certificate");
        System.out.println("  --tls-password PW    password of that keystore");
        System.out.println("  --tls-cert F         PEM certificate (chain) used instead of a keystore");
        System.out.println("  --tls-key F          PEM PKCS#8 private key belonging to that certificate");
        System.out.println("  --quiet              log joins/leaves only, not the big frames");
        System.out.println("  --selftest           run the built-in check and exit");
        System.out.println("  -h, --help           this text");
        System.out.println("rooms: the last url path segment, for example /c/<room>");
        System.out.println("  ws/wss: a normal websocket upgrade on that path");
        System.out.println("  http  : GET <room>?uid=..[&wait=ms] polls, POST <room>?uid=.. publishes");
    }

    public static void main(String[] args) throws Exception {
        String host = "0.0.0.0";
        int port = 8765;
        int tlsPort = 0;
        String tlsStore = null;
        String tlsPassword = null;
        String tlsCert = null;
        String tlsKey = null;
        boolean selftest = false;
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            String inline = null;
            int equals = arg.indexOf('=');
            if (equals > 0) {
                inline = arg.substring(equals + 1);
                arg = arg.substring(0, equals);
            }
            if (arg.equals("--host")) {
                if (inline != null) {
                    host = inline;
                } else if (i + 1 < args.length) {
                    host = args[++i];
                }
            } else if (arg.equals("--port") || arg.equals("-P")) {
                String text = inline;
                if (text == null && i + 1 < args.length) {
                    text = args[++i];
                }
                port = parsePortArg(text, port);
            } else if (arg.equals("--tls-port")) {
                String text = inline;
                if (text == null && i + 1 < args.length) {
                    text = args[++i];
                }
                tlsPort = parsePortArg(text, tlsPort);
            } else if (arg.equals("--tls-keystore")) {
                tlsStore = inline != null ? inline : (i + 1 < args.length ? args[++i] : null);
            } else if (arg.equals("--tls-password")) {
                tlsPassword = inline != null ? inline : (i + 1 < args.length ? args[++i] : null);
            } else if (arg.equals("--tls-cert")) {
                tlsCert = inline != null ? inline : (i + 1 < args.length ? args[++i] : null);
            } else if (arg.equals("--tls-key")) {
                tlsKey = inline != null ? inline : (i + 1 < args.length ? args[++i] : null);
            } else if (arg.equals("--quiet")) {
                verbose = false;
            } else if (arg.equals("--selftest")) {
                selftest = true;
            } else if (arg.equals("--help") || arg.equals("-h")) {
                printUsage();
                return;
            } else {
                System.err.println("[relay] unknown argument ignored: " + arg);
            }
        }
        SSLContext tls = null;
        if (tlsStore != null) {
            tls = tlsContextFromStore(tlsStore, tlsPassword);
        } else if (tlsCert != null && tlsKey != null) {
            tls = tlsContextFromPem(tlsCert, tlsKey);
        } else if (tlsCert != null || tlsKey != null) {
            System.err.println("[relay] --tls-cert and --tls-key have to be used together");
            return;
        }
        if (selftest) {
            System.exit(runSelftest(tls));
        }
        if (tlsPort > 0 && tls == null) {
            System.err.println("[relay] --tls-port needs --tls-keystore/--tls-password"
                    + " or --tls-cert/--tls-key");
            return;
        }
        startHttpSweeper();
        ServerSocket plain = openServer(host, port, null);
        int plainPort = plain.getLocalPort();
        System.out.println("WebSocket relay listening on " + host + ":" + plainPort);
        System.out.println("  plain: ws://<host>:" + plainPort + "/c/<room>    http://<host>:"
                + plainPort + "/c/<room>");
        startAcceptThread(plain, "ws-relay-accept");
        if (tlsPort > 0) {
            ServerSocket secure = openServer(host, tlsPort, tls);
            int securePort = secure.getLocalPort();
            System.out.println("  tls  : wss://<host>:" + securePort + "/c/<room>   https://<host>:"
                    + securePort + "/c/<room>");
            startAcceptThread(secure, "ws-relay-accept-tls");
        }
        System.out.println("  rooms: the last url path segment; frames go to the other members");
        System.out.println("  http : GET <room>?uid=..&wait=ms polls, POST <room>?uid=.. publishes");
        System.out.println("Ctrl+C stops the relay.");
        while (true) {
            Thread.sleep(3600_000L);
        }
    }
}








