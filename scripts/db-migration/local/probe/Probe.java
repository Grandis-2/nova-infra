import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.io.IOException;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * G3 쓰기 프로브. 앱과 같은 드라이버 · 풀 설정으로 ProxySQL 을 거쳐 계속 쓰고 읽으며 결과를 남긴다.
 *
 * <p>풀 넷은 운영 서비스의 드라이버 · 풀 설정을 따른다(nova-infra application/*.yml, be PreorderDefaults):
 * preorder(연결 대기 2초, 상태 캐시 · 읽기 전용 미전달) · member(상태 캐시)는 proxysql1, catalog(기본값) · mock(useLocalSessionState)은
 * proxysql2 로 붙는다. 풀을 만들면 Hibernate 가 기동 때 보내는 조회를 한 연결에서 보내고 풀에 돌려준다(그 연결이 고정되는지 본다).
 * 쓰기 트랜잭션은 행 추가 + 경합 행 갱신(재고처럼) + 어느 서버 · 격리 수준에서 처리됐는지 조회다.
 * 서버 이름은 복제되지 않는 g3meta.server 에서 읽는다. {@code @@server_uuid} 같은 변수 조회는 ProxySQL 의 멀티플렉싱을
 * 꺼서 시험 결과를 흐리므로 쓰지 않는다(격리 수준은 ProxySQL 이 예외로 두는 변수라 그대로 읽는다).
 * {@code PROBE_OUT/stop} 파일이 생기면 멈추고, 확인 응답을 받은 쓰기 번호(acked.txt)와 요약(summary.txt)을 남긴다.
 */
public class Probe {

    record Event(long atMillis, String pool, char kind, long seq, long micros, String server, String isolation, String error) {}

    static final Path OUT = Path.of(env("PROBE_OUT", "/work/probe"));
    static final int WRITERS = Integer.parseInt(env("PROBE_WRITERS", "2"));
    static final int READERS = Integer.parseInt(env("PROBE_READERS", "1"));
    static final long INTERVAL_MS = Long.parseLong(env("PROBE_INTERVAL_MS", "200"));
    static final String PARAMS = "?serverTimezone=UTC&characterEncoding=UTF-8&sslMode=REQUIRED"; // 운영 JDBC URL 과 같다

    static final AtomicLong SEQ = new AtomicLong(Long.parseLong(env("PROBE_SEQ_START", "0")));
    static final ConcurrentLinkedQueue<Event> EVENTS = new ConcurrentLinkedQueue<>();
    static volatile boolean running = true;

    public static void main(String[] args) throws Exception {
        Files.createDirectories(OUT);
        Files.deleteIfExists(OUT.resolve("stop"));
        Map<String, String> sessionCache = Map.of("useLocalSessionState", "true", "useLocalTransactionState", "true",
                "cacheServerConfiguration", "true");
        Map<String, String> preorderOpts = new TreeMap<>(sessionCache);
        preorderOpts.put("readOnlyPropagatesToServer", "false");
        List<HikariDataSource> pools = List.of(
                pool("preorder", "proxysql1", 2_000, preorderOpts),
                pool("member", "proxysql1", 30_000, sessionCache),
                pool("catalog", "proxysql2", 30_000, Map.of()),
                pool("mock", "proxysql2", 30_000, Map.of("useLocalSessionState", "true")));
        // 앞선 실행이 남긴 번호 다음부터 쓴다(여러 번 돌려도 기본 키가 겹치지 않게)
        try (Connection c = pools.get(0).getConnection(); Statement st = c.createStatement();
             ResultSet rs = st.executeQuery("SELECT COALESCE(MAX(seq), 0) FROM g3_probe_write")) {
            rs.next();
            SEQ.set(Math.max(SEQ.get(), rs.getLong(1)));
        }

        List<Thread> threads = new ArrayList<>();
        for (HikariDataSource ds : pools) {
            for (int i = 0; i < WRITERS; i++) threads.add(Thread.ofPlatform().name(ds.getPoolName() + "-w" + i).start(() -> writeLoop(ds)));
            for (int i = 0; i < READERS; i++) threads.add(Thread.ofPlatform().name(ds.getPoolName() + "-r" + i).start(() -> readLoop(ds)));
        }

        Stats stats = new Stats();
        try (PrintWriter timeline = new PrintWriter(Files.newBufferedWriter(OUT.resolve("timeline.tsv")));
             PrintWriter events = new PrintWriter(Files.newBufferedWriter(OUT.resolve("events.tsv")))) {
            timeline.println("time\twrite_ok\twrite_err\tread_ok\tread_err\tmax_ms\tservers");
            events.println("at\tpool\tkind\tseq\tmicros\tserver\tisolation\terror");
            while (running) {
                TimeUnit.SECONDS.sleep(1);
                if (Files.exists(OUT.resolve("stop"))) running = false;
                stats.drainTo(timeline, events);
            }
            for (Thread t : threads) t.join();
            stats.drainTo(timeline, events);
        }
        pools.forEach(HikariDataSource::close);
        stats.writeSummary();
    }

    static HikariDataSource pool(String user, String proxy, long connectionTimeoutMs, Map<String, String> driverOptions) throws SQLException {
        HikariConfig c = new HikariConfig();
        c.setPoolName(user);
        c.setJdbcUrl("jdbc:mysql://" + proxy + ":3306/shop" + PARAMS);
        c.setUsername(user);
        c.setPassword(env("PW_" + user.toUpperCase(), null));
        c.setMaximumPoolSize(10);
        c.setTransactionIsolation("TRANSACTION_READ_COMMITTED");
        c.setConnectionTimeout(connectionTimeoutMs);
        driverOptions.forEach(c::addDataSourceProperty);
        // 나머지는 앱처럼 HikariCP 기본값(maxLifetime 30분, keepalive 2분)
        HikariDataSource ds = new HikariDataSource(c);
        if (!"0".equals(env("PROBE_HIBERNATE_BOOT", "1"))) {
            try (Connection conn = ds.getConnection(); Statement st = conn.createStatement();
                 ResultSet rs = st.executeQuery("SELECT @@character_set_database, @@sql_mode")) {
                rs.next();
            }
        }
        return ds;
    }

    static void writeLoop(HikariDataSource ds) {
        while (running) {
            long seq = SEQ.incrementAndGet();
            long t0 = System.nanoTime();
            String server = null, isolation = null, error = null;
            try (Connection c = ds.getConnection()) {
                c.setAutoCommit(false);
                try {
                    // pool 값에 '@' 를 넣는다. Connector/J 는 값을 SQL 문자열 안에 넣어 보내므로, 이메일 같은 값이
                    // ProxySQL 의 멀티플렉싱을 끄지 않는지 함께 본다
                    try (PreparedStatement ps = c.prepareStatement(
                            "INSERT INTO g3_probe_write (seq, pool, written_on, created_at) SELECT ?, ?, name, UTC_TIMESTAMP(6) FROM g3meta.server")) {
                        ps.setLong(1, seq);
                        ps.setString(2, ds.getPoolName() + "@w");
                        ps.executeUpdate();
                    }
                    try (Statement st = c.createStatement()) {
                        st.executeUpdate("UPDATE g3_probe_counter SET value = value + 1 WHERE id = 1");
                        // 아웃박스처럼 AUTO_INCREMENT 표에 쓴다. ProxySQL 은 자동 증가 값이 생긴 뒤 몇 쿼리 동안 연결을 묶는다
                        st.executeUpdate("INSERT INTO g3_probe_outbox (seq) VALUES (" + seq + ")");
                        try (ResultSet rs = st.executeQuery("SELECT name FROM g3meta.server")) {
                            rs.next();
                            server = rs.getString(1);
                        }
                        // 앱(preorder 기동 검사)과 같은 단독 형태. ProxySQL 은 이 변수를 멀티플렉싱 예외로 둔다
                        try (ResultSet rs = st.executeQuery("SELECT @@transaction_isolation")) {
                            rs.next();
                            isolation = rs.getString(1);
                        }
                    }
                    c.commit();
                } catch (SQLException e) {
                    try { c.rollback(); } catch (SQLException ignored) { }
                    throw e;
                }
            } catch (SQLException e) {
                error = e.getClass().getSimpleName() + " [" + e.getSQLState() + "/" + e.getErrorCode() + "] " + e.getMessage();
            }
            EVENTS.add(new Event(System.currentTimeMillis(), ds.getPoolName(), 'W', seq, (System.nanoTime() - t0) / 1_000, server, isolation, error));
            sleep(INTERVAL_MS);
        }
    }

    static void readLoop(HikariDataSource ds) {
        while (running) {
            long t0 = System.nanoTime();
            String server = null, error = null;
            // Spring @Transactional(readOnly = true) 와 같은 순서: 읽기 전용 표시 → 트랜잭션 → 해제
            try (Connection c = ds.getConnection()) {
                c.setReadOnly(true);
                c.setAutoCommit(false);
                try (Statement st = c.createStatement();
                     ResultSet rs = st.executeQuery("SELECT (SELECT COUNT(*) FROM g3_probe_write), name FROM g3meta.server")) {
                    rs.next();
                    server = rs.getString(2);
                }
                c.commit();
                c.setAutoCommit(true);
                c.setReadOnly(false);
            } catch (SQLException e) {
                error = e.getClass().getSimpleName() + " [" + e.getSQLState() + "/" + e.getErrorCode() + "] " + e.getMessage();
            }
            EVENTS.add(new Event(System.currentTimeMillis(), ds.getPoolName(), 'R', 0, (System.nanoTime() - t0) / 1_000, server, null, error));
            sleep(INTERVAL_MS);
        }
    }

    /** 1초마다 이벤트를 모아 시간표와 원본을 쓰고, 끝에 요약을 남긴다. */
    static final class Stats {
        final List<Long> acked = new ArrayList<>();
        final List<String> errors = new ArrayList<>();
        final Map<String, Long> writesByServer = new TreeMap<>();
        long writeOk, writeErr, readOk, readErr, maxMicros, isolationMismatch, over300, over1000;
        long firstAt, lastAt;

        void drainTo(PrintWriter timeline, PrintWriter events) {
            long wOk = 0, wErr = 0, rOk = 0, rErr = 0, max = 0;
            Map<String, Long> servers = new TreeMap<>();
            Event e;
            while ((e = EVENTS.poll()) != null) {
                if (firstAt == 0) firstAt = e.atMillis();
                lastAt = e.atMillis();
                max = Math.max(max, e.micros());
                maxMicros = Math.max(maxMicros, e.micros());
                if (e.micros() > 300_000) over300++;
                if (e.micros() > 1_000_000) over1000++;
                events.printf("%s\t%s\t%c\t%d\t%d\t%s\t%s\t%s%n", Instant.ofEpochMilli(e.atMillis()), e.pool(), e.kind(), e.seq(), e.micros(),
                        nz(e.server()), nz(e.isolation()), nz(e.error()));
                if (e.error() != null) {
                    errors.add(Instant.ofEpochMilli(e.atMillis()) + " " + e.pool() + " " + e.kind() + " " + e.error());
                    if (e.kind() == 'W') wErr++; else rErr++;
                    continue;
                }
                servers.merge(shortUuid(e.server()), 1L, Long::sum);
                if (e.kind() == 'W') {
                    wOk++;
                    acked.add(e.seq());
                    writesByServer.merge(e.server(), 1L, Long::sum);
                    if (!"READ-COMMITTED".equals(e.isolation())) isolationMismatch++;
                } else {
                    rOk++;
                }
            }
            writeOk += wOk; writeErr += wErr; readOk += rOk; readErr += rErr;
            timeline.printf("%s\t%d\t%d\t%d\t%d\t%.1f\t%s%n", Instant.now(), wOk, wErr, rOk, rErr, max / 1000.0, servers);
            timeline.flush();
            events.flush();
            System.out.printf("%s 쓰기 %d(오류 %d) 읽기 %d(오류 %d) 최대 %.1fms 서버 %s%n", Instant.now(), wOk, wErr, rOk, rErr, max / 1000.0, servers);
        }

        void writeSummary() throws IOException {
            acked.sort(null);
            Files.write(OUT.resolve("acked.txt"), acked.stream().map(String::valueOf).toList());
            Files.write(OUT.resolve("errors.txt"), errors);
            List<String> s = new ArrayList<>();
            s.add("기간 " + Instant.ofEpochMilli(firstAt) + " ~ " + Instant.ofEpochMilli(lastAt));
            s.add("쓰기 성공 " + writeOk + ", 쓰기 오류 " + writeErr + ", 읽기 성공 " + readOk + ", 읽기 오류 " + readErr);
            s.add("최대 지연 " + String.format("%.1f", maxMicros / 1000.0) + "ms, 300ms 넘은 요청 " + over300 + ", 1초 넘은 요청 " + over1000);
            s.add("격리 수준이 READ-COMMITTED 가 아닌 쓰기 " + isolationMismatch);
            s.add("서버별 쓰기 " + writesByServer);
            Files.write(OUT.resolve("summary.txt"), s);
            s.forEach(System.out::println);
        }
    }

    static String shortUuid(String server) { return server == null ? "-" : server; }
    static String nz(String s) { return s == null ? "" : s.replace('\t', ' ').replace('\n', ' '); }
    static String env(String name, String fallback) { String v = System.getenv(name); return v == null || v.isBlank() ? fallback : v; }
    static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } }
}
