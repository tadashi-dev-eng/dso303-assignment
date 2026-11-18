// Schema + seed data. Run by invoking the api function with {"action":"migrate"}
// (scripts/deploy.sh does this after `terraform apply`). Idempotent.
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS users (
     user_id    TEXT PRIMARY KEY,
     email      TEXT NOT NULL UNIQUE,
     full_name  TEXT NOT NULL,
     role       TEXT NOT NULL CHECK (role IN ('student','tutor','admin'))
   )`,
  `CREATE TABLE IF NOT EXISTS courses (
     course_id  TEXT PRIMARY KEY,
     title      TEXT NOT NULL,
     tutor_id   TEXT NOT NULL REFERENCES users(user_id)
   )`,
  `CREATE TABLE IF NOT EXISTS exams (
     exam_id      TEXT PRIMARY KEY,
     course_id    TEXT NOT NULL REFERENCES courses(course_id),
     title        TEXT NOT NULL,
     duration_min INT  NOT NULL,
     opens_at     TIMESTAMPTZ NOT NULL,
     closes_at    TIMESTAMPTZ NOT NULL,
     released     BOOLEAN NOT NULL DEFAULT FALSE
   )`,
  `CREATE TABLE IF NOT EXISTS questions (
     exam_id     TEXT NOT NULL REFERENCES exams(exam_id),
     question_id TEXT NOT NULL,
     qtype       TEXT NOT NULL CHECK (qtype IN ('mcq','short')),
     prompt      TEXT NOT NULL,
     options     TEXT,
     answer_key  TEXT,
     marks       INT NOT NULL DEFAULT 1,
     PRIMARY KEY (exam_id, question_id)
   )`,
  `CREATE TABLE IF NOT EXISTS attempts (
     attempt_id  TEXT PRIMARY KEY,
     exam_id     TEXT NOT NULL REFERENCES exams(exam_id),
     student_id  TEXT NOT NULL REFERENCES users(user_id),
     started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
     ends_at     TIMESTAMPTZ NOT NULL,
     submitted_at TIMESTAMPTZ,
     UNIQUE (exam_id, student_id)
   )`,
  `CREATE TABLE IF NOT EXISTS results (
     attempt_id  TEXT PRIMARY KEY REFERENCES attempts(attempt_id),
     mcq_score   INT NOT NULL,
     mcq_total   INT NOT NULL,
     status      TEXT NOT NULL,
     marked_at   TIMESTAMPTZ NOT NULL DEFAULT now()
   )`,
];

export const SEED = [
  `INSERT INTO users VALUES
     ('stu-0001','student0001@students.example-university.edu','Student 0001','student'),
     ('stu-0002','student0002@students.example-university.edu','Student 0002','student'),
     ('tut-0001','tutor0001@staff.example-university.edu','Tutor 0001','tutor'),
     ('adm-0001','admin0001@staff.example-university.edu','Admin 0001','admin')
   ON CONFLICT DO NOTHING`,
  `INSERT INTO courses VALUES ('DSO303','Cloud Native Solution Design','tut-0001') ON CONFLICT DO NOTHING`,
  `INSERT INTO exams VALUES ('dso303-midterm','DSO303','DSO303 Mid-term (MCQ + short answer)',60,
     now() - interval '1 hour', now() + interval '30 days', FALSE) ON CONFLICT DO NOTHING`,
  `INSERT INTO questions VALUES
     ('dso303-midterm','q1','mcq','Which service gives a relational database a synchronous standby in a second AZ?','["S3","RDS/Aurora Multi-AZ","CloudFront","SQS"]','RDS/Aurora Multi-AZ',2),
     ('dso303-midterm','q2','mcq','Which service decouples auto-marking from the request path?','["SQS","Route 53","WAF","KMS"]','SQS',2),
     ('dso303-midterm','q3','mcq','What keeps a 50 MB upload off the API tier?','["Bigger Lambda","S3 presigned URL","NAT gateway","EBS"]','S3 presigned URL',2),
     ('dso303-midterm','q4','short','Explain RPO vs RTO in one sentence each.',NULL,NULL,4)
   ON CONFLICT DO NOTHING`,
];
