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

한 줄 요약

멱등성 체크/등록 = “같은 요청은 한 번만”을 보장하는 DB 단일 소유권 확보 절차.
그래서 트랜잭션의 맨 앞에서 UNIQUE 기반 INSERT로 깃발을 꽂고, 성공/실패 결과를 같은 트랜잭션에서 기록해 중복·재시도·장애 상황에서도 재고가 두 번 줄지 않게 만듭니다.



멱등성 테이블(idempotency)은 **“같은 요청을 여러 번 보내더라도 DB에는 단 1번만 반영되게 하는 안전장치”**예요.
문서에서 예약(T1)과 주문(T2) 두 단계에서 모두 쓰이는 이유를 정리해드릴게요.

1. T1 (예약하기)에서의 멱등성

사용자가 구매 버튼을 연타하거나, 네트워크 문제로 동일 요청이 여러 번 서버로 들어올 수 있음.

예를 들어 "홍길동, hold_12345"라는 예약 요청이 3번 들어오면:

idempotency (user_id, idem_key UNIQUE) 제약 때문에 첫 번째만 성공하고,

나머지 2개는 duplicate key로 무시 → 이미 기록된 응답을 그대로 반환.

→ 그래서 예약은 반드시 1번만 만들어짐.

2. T2 (주문 확정)에서의 멱등성

결제 PG사가 같은 결제 성공 웹훅을 여러 번 보낼 수 있음.

"홍길동, payment_abc123" 요청이 2번 들어오면:

첫 번째만 INSERT 되고 처리 계속됨.

두 번째는 이미 idempotency에 기록된 응답을 돌려주고 더 이상 주문을 만들지 않음.

→ 그래서 같은 결제에 대해 주문은 반드시 1번만 만들어짐.

3. 왜 예약(T1)과 주문(T2) 둘 다에 필요할까?

예약 시 멱등성 없으면: 버튼 연타로 같은 사람이 여러 개 재고를 차감해버릴 수 있음.

주문 시 멱등성 없으면: PG 중복 알림 때문에 동일 예약에서 주문이 2개 생길 수 있음.

두 경우 모두 "100개만 팔아야 하는데 101개 팔림" 같은 오류를 유발.

✅ 요약

T1 멱등성: “예약은 사용자 요청 1번만 인정”

T2 멱등성: “주문은 결제 건당 1번만 인정”

두 번 쓰이지만 각각 지켜주는 대상이 다름 → 합쳐져서 전체 흐름에서 중복을 완전히 제거해 줌.