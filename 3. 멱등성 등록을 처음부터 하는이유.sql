좋은 질문! 멱등성(Idempotency) 체크/등록은 “같은 요청이 여러 번 들어와도 부작용(재고 차감, 주문 생성)이 한 번만 일어나게” 하는 안전핀이에요.
왜 트랜잭션 시작 직후, 제일 먼저 하냐면 — 중복 요청끼리 경합할 때 먼저 ‘내가 이 요청 맡음’이라고 깃발을 꽂아 두지 않으면 둘 다 재고를 깎아버릴 수 있기 때문이에요.

왜 필요한가?

실전에서는 같은 주문 요청이 쉽게 중복됩니다.

사용자가 더블클릭/새로고침, 모바일 네트워크 재시도

API 게이트웨이/로드밸런서의 자동 재시도

PG(결제사) 웹훅/콜백 중복 전송

이때 같은 요청 키(Idempotency-Key) 로 오면, 두 번째부터는 이미 처리됐는지 확인하고, 처리됐다면 같은 응답을 그대로 반환해야 “재고 2번 차감” 같은 사고를 막을 수 있어요.

‘트랜잭션 첫 줄’에서 하는 이유

중복 두 요청이 거의 동시에 들어오는 최악의 타이밍을 상상해보면:

먼저 온 요청이 재고를 깎고 나중에 멱등성 테이블에 기록하면,

뒤이어 온 요청도 재고를 깎을 틈이 생깁니다. (경쟁적 레이스)

그래서 BEGIN 직후 1순위로 멱등성 등록을 시도합니다.
유니크 제약에 걸려 단 한 요청만 “이 키의 주인”이 되고, 나머지는 기존 결과를 읽어 돌려보내거나, 진행 중이면 대기/에러로 처리합니다.

최소 구현(스키마 & 흐름)
테이블(예: MySQL)
CREATE TABLE idempotency (
  user_id      BIGINT NOT NULL,
  idem_key     CHAR(36) NOT NULL,             -- 클라가 보낸 UUID 같은 키
  request_hash BINARY(32) NOT NULL,           -- body+method+path 해시(SHA256)
  status       ENUM('IN_PROGRESS','SUCCEEDED','FAILED') NOT NULL,
  response_json JSON NULL,                    -- 성공 시 응답 스냅샷
  created_at   DATETIME NOT NULL,
  updated_at   DATETIME NOT NULL,
  UNIQUE KEY uq_user_key (user_id, idem_key)
);

트랜잭션 흐름(예약 /reserve 예시)
-- T1 시작 (BEGIN)

-- 1) 멱등성 '등록 시도' (깃발 꽂기)
INSERT INTO idempotency(user_id, idem_key, request_hash, status, created_at, updated_at)
VALUES(:uid, :key, :hash, 'IN_PROGRESS', NOW(), NOW())
ON DUPLICATE KEY UPDATE idem_key = idem_key;   -- 아무 것도 안 바꿈(=Do Nothing)

-- 새로 들어갔는지 확인
SELECT ROW_COUNT() INTO @affected;
IF @affected = 0 THEN
  -- 기존 요청이 이미 있음: 그 상태 확인
  SELECT status, response_json, request_hash
  FROM idempotency
  WHERE user_id=:uid AND idem_key=:key
  -- (잠금 없이 읽고, IN_PROGRESS면 짧게 폴링하거나 409/202 반환)

  -- (보호) 서로 다른 요청 바디로 같은 키를 써버린 경우
  IF request_hash != :hash THEN
    -- 409: Idempotency-Key 재사용 오류
  END IF;

  IF status = 'SUCCEEDED' THEN
    -- 저장된 response_json 그대로 반환하고 커밋(또는 롤백)
  ELSEIF status = 'IN_PROGRESS' THEN
    -- 짧게 대기 후 재확인 or 409/202로 "처리 중"
  ELSEIF status = 'FAILED' THEN
    -- 동일 실패 응답 반환(또는 정책대로 재시도 유도)
  END IF;
  -- 여기서 종료
END IF;

-- 2) (여기까지 왔으면 '이 키'의 주인) 실제 부작용 수행
--    예: 재고 조건부 감액 + 예약 생성 등
--    실패 시 ROLLBACK; 멱등성 행도 같이 취소됨

-- 3) 성공 응답 스냅샷 기록 (같은 트랜잭션 안에서!)
UPDATE idempotency
SET status='SUCCEEDED', response_json=:resp, updated_at=NOW()
WHERE user_id=:uid AND idem_key=:key;

-- 4) 커밋


핵심: 멱등성 등록(INSERT)과 실제 작업, 그리고 응답 스냅샷 UPDATE를 한 트랜잭션에 묶기
→ “작업만 되고 기록은 안 남는” 반쪽 상태를 없애요.

구현 팁(실무 체크리스트)

키 스코프: (method, path, body)까지 포함한 request_hash를 저장해 키 오남용(다른 내용에 같은 키 재사용)을 409로 막기.

키 수명(TTL): 10~60분 정도 보존(대규모 세일이면 24h도), 파티션/주기 삭제.

상태 IN_PROGRESS 처리:

간단히는 409/202 반환 + 클라 재시도 권장,

혹은 짧은 폴링(수백 ms) 후 SUCCEEDED면 즉시 응답.

결제/콜백: PG의 고유 거래ID를 멱등성 키로 쓰면 중복 웹훅도 안전.

장애 복원: 서버 크래시로 IN_PROGRESS가 남을 수 → 짧은 만료 시간 또는 백그라운드 클리너로 정리(단, 실제 주문 기록과 함께 판단).

분산 환경: 여러 앱 인스턴스에서도 DB의 UNIQUE 제약이 단 하나만 통과시키므로 안전. (Redis NX를 보조로 써도, 최종 보증은 DB가 좋습니다.)

한 줄 요약

멱등성 체크/등록 = “같은 요청은 한 번만”을 보장하는 DB 단일 소유권 확보 절차.
그래서 트랜잭션의 맨 앞에서 UNIQUE 기반 INSERT로 깃발을 꽂고, 성공/실패 결과를 같은 트랜잭션에서 기록해 중복·재시도·장애 상황에서도 재고가 두 번 줄지 않게 만듭니다.