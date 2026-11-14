-- =====================================================================
-- Library Management System (MySQL 8.x)
-- Run the WHOLE file at once: Ctrl+A, then Ctrl+Shift+Enter
-- (It drops and recreates the tables, so it is safe to re-run.)
-- =====================================================================

CREATE DATABASE IF NOT EXISTS library_management;
USE library_management;

-- ---------------------------------------------------------------------
-- 1. CLEAN UP (child tables first)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fines;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS book_authors;
DROP TABLE IF EXISTS book_copies;
DROP TABLE IF EXISTS books;
DROP TABLE IF EXISTS authors;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS users;

-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------
CREATE TABLE users (
  user_id   INT AUTO_INCREMENT PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  email     VARCHAR(100) NOT NULL UNIQUE,
  role      ENUM('MEMBER','STAFF') NOT NULL DEFAULT 'MEMBER',
  status    ENUM('ACTIVE','BLOCKED') NOT NULL DEFAULT 'ACTIVE'
);

CREATE TABLE categories (
  category_id INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE authors (
  author_id INT AUTO_INCREMENT PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE books (
  book_id     INT AUTO_INCREMENT PRIMARY KEY,
  isbn        VARCHAR(20)  NOT NULL UNIQUE,
  title       VARCHAR(200) NOT NULL,
  category_id INT NULL,
  FOREIGN KEY (category_id) REFERENCES categories(category_id)
);

CREATE TABLE book_authors (
  book_id   INT NOT NULL,
  author_id INT NOT NULL,
  PRIMARY KEY (book_id, author_id),
  FOREIGN KEY (book_id)   REFERENCES books(book_id),
  FOREIGN KEY (author_id) REFERENCES authors(author_id)
);

CREATE TABLE book_copies (
  copy_id    INT AUTO_INCREMENT PRIMARY KEY,
  book_id    INT NOT NULL,
  barcode    VARCHAR(50) NOT NULL UNIQUE,
  shelf_code VARCHAR(20),
  status     ENUM('AVAILABLE','ISSUED','LOST') NOT NULL DEFAULT 'AVAILABLE',
  FOREIGN KEY (book_id) REFERENCES books(book_id)
);

CREATE TABLE transactions (
  transaction_id INT AUTO_INCREMENT PRIMARY KEY,
  copy_id        INT  NOT NULL,
  user_id        INT  NOT NULL,
  issued_by      INT  NOT NULL,
  issued_on      DATE NOT NULL,
  due_on         DATE NOT NULL,
  returned_on    DATE NULL,
  -- generated column: equals copy_id while the loan is open, NULL once returned.
  -- The unique index on it stops one copy being on two open loans at once.
  open_copy_id   INT GENERATED ALWAYS AS (CASE WHEN returned_on IS NULL THEN copy_id END) STORED,
  UNIQUE KEY uq_one_open_loan_per_copy (open_copy_id),
  FOREIGN KEY (copy_id)   REFERENCES book_copies(copy_id),
  FOREIGN KEY (user_id)   REFERENCES users(user_id),
  FOREIGN KEY (issued_by) REFERENCES users(user_id)
);

CREATE TABLE fines (
  fine_id        INT AUTO_INCREMENT PRIMARY KEY,
  transaction_id INT NOT NULL UNIQUE,
  amount         DECIMAL(8,2) NOT NULL,
  paid_on        DATE NULL,
  FOREIGN KEY (transaction_id) REFERENCES transactions(transaction_id)
);

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------
-- Each trigger is a single statement (no BEGIN...END), so no custom
-- delimiter is needed. A broken rule sets a NOT NULL column to NULL,
-- which makes the INSERT fail.

-- Issue check 1: copy must be AVAILABLE   (error: Column 'copy_id' cannot be null)
CREATE TRIGGER trg_check_copy
BEFORE INSERT ON transactions
FOR EACH ROW
SET NEW.copy_id = (SELECT copy_id FROM book_copies
                   WHERE copy_id = NEW.copy_id AND status = 'AVAILABLE');

-- Issue check 2: user must be ACTIVE      (error: Column 'user_id' cannot be null)
CREATE TRIGGER trg_check_user
BEFORE INSERT ON transactions
FOR EACH ROW
SET NEW.user_id = (SELECT user_id FROM users
                   WHERE user_id = NEW.user_id AND status = 'ACTIVE');

-- Issue check 3: max 3 open loans per user (error: Column 'user_id' cannot be null)
CREATE TRIGGER trg_check_limit
BEFORE INSERT ON transactions
FOR EACH ROW
SET NEW.user_id = IF((SELECT COUNT(*) FROM transactions
                      WHERE user_id = NEW.user_id AND returned_on IS NULL) < 3,
                     NEW.user_id, NULL);

-- After an issue: mark the copy ISSUED
CREATE TRIGGER trg_issue_mark
AFTER INSERT ON transactions
FOR EACH ROW
UPDATE book_copies SET status = 'ISSUED' WHERE copy_id = NEW.copy_id;

-- After a return: free the copy
CREATE TRIGGER trg_return_free
AFTER UPDATE ON transactions
FOR EACH ROW
UPDATE book_copies SET status = 'AVAILABLE'
WHERE copy_id = NEW.copy_id
  AND OLD.returned_on IS NULL AND NEW.returned_on IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3b. SAMPLE DATA
-- ---------------------------------------------------------------------
INSERT INTO users (full_name, email, role) VALUES
  ('Arun Kumar',   'arun@example.com',   'MEMBER'),   -- user 1
  ('Priya Sharma', 'priya@example.com',  'MEMBER'),   -- user 2
  ('Staff Ravi',   'ravi@library.org',   'STAFF');    -- user 3

INSERT INTO categories (name) VALUES ('Fiction'), ('Programming');

INSERT INTO authors (full_name) VALUES
  ('George Orwell'),
  ('Dennis Ritchie'),
  ('Brian Kernighan');

INSERT INTO books (isbn, title, category_id) VALUES
  ('9780451524935', '1984', 1),                          -- book 1
  ('9780131103627', 'The C Programming Language', 2);    -- book 2

INSERT INTO book_authors (book_id, author_id) VALUES
  (1, 1),
  (2, 2),
  (2, 3);

INSERT INTO book_copies (book_id, barcode, shelf_code) VALUES
  (1, 'BC-0001', 'A1'),   -- copy 1
  (1, 'BC-0002', 'A1'),   -- copy 2
  (2, 'BC-0003', 'B2');   -- copy 3

SHOW TABLES;

-- ---------------------------------------------------------------------
-- 4. CORE QUERIES
-- ---------------------------------------------------------------------

-- 4.1 ISSUE a book -----------------------------------------------------
-- Look up an available copy of a title by ISBN, then issue it.
-- Loan period here is 14 days. The trigger checks availability, user
-- status and loan limit, and flips the copy to ISSUED.

-- (a) Find an available copy of the book
SELECT c.copy_id, c.barcode, c.shelf_code
FROM book_copies c
JOIN books b ON b.book_id = c.book_id
WHERE b.isbn = '9780451524935' AND c.status = 'AVAILABLE'
ORDER BY c.copy_id
LIMIT 1;

-- (b) Issue it (copy 1 to user 1, handled by staff user 3)
INSERT INTO transactions (copy_id, user_id, issued_by, issued_on, due_on)
VALUES (1, 1, 3, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 14 DAY));

-- 4.2 RETURN a book ----------------------------------------------------
-- Closes the open loan by barcode; the trigger frees the copy.
-- (The copy_id is read into a variable first, because MySQL does not
--  allow a trigger to change book_copies while the same statement is
--  also reading book_copies in a subquery.)
SET @return_copy_id = (SELECT copy_id FROM book_copies WHERE barcode = 'BC-0001');

UPDATE transactions
SET returned_on = CURDATE()
WHERE returned_on IS NULL
  AND copy_id = @return_copy_id;

-- 4.3 ASSESS a fine on return (Rs. 2 per day late) ---------------------
INSERT INTO fines (transaction_id, amount)
SELECT t.transaction_id,
       GREATEST(DATEDIFF(t.returned_on, t.due_on), 0) * 2
FROM transactions t
WHERE t.returned_on > t.due_on
  AND NOT EXISTS (SELECT 1 FROM fines f WHERE f.transaction_id = t.transaction_id);

-- 4.4 TRACKING queries -------------------------------------------------

-- Books currently on loan, with borrower and due date
SELECT t.transaction_id, b.title, c.barcode, u.full_name AS borrower,
       t.issued_on, t.due_on
FROM transactions t
JOIN book_copies c ON c.copy_id = t.copy_id
JOIN books b       ON b.book_id = c.book_id
JOIN users u       ON u.user_id = t.user_id
WHERE t.returned_on IS NULL
ORDER BY t.due_on;

-- Overdue loans and how many days late (as of today)
SELECT u.full_name, u.email, b.title, t.due_on,
       DATEDIFF(CURDATE(), t.due_on) AS days_overdue
FROM transactions t
JOIN book_copies c ON c.copy_id = t.copy_id
JOIN books b       ON b.book_id = c.book_id
JOIN users u       ON u.user_id = t.user_id
WHERE t.returned_on IS NULL AND t.due_on < CURDATE()
ORDER BY days_overdue DESC;

-- Full borrowing history of one user
SELECT b.title, t.issued_on, t.due_on, t.returned_on,
       CASE WHEN t.returned_on IS NULL THEN 'OUT' ELSE 'RETURNED' END AS state
FROM transactions t
JOIN book_copies c ON c.copy_id = t.copy_id
JOIN books b       ON b.book_id = c.book_id
WHERE t.user_id = 1
ORDER BY t.issued_on DESC;

-- Availability per title (total copies vs. available now)
SELECT b.title,
       COUNT(c.copy_id)                                         AS total_copies,
       SUM(CASE WHEN c.status = 'AVAILABLE' THEN 1 ELSE 0 END)  AS available_copies
FROM books b
LEFT JOIN book_copies c ON c.book_id = b.book_id
GROUP BY b.book_id, b.title
ORDER BY b.title;

-- Search the catalogue by title or author, with authors listed
SELECT b.title, GROUP_CONCAT(a.full_name SEPARATOR ', ') AS authors, cat.name AS category
FROM books b
JOIN book_authors ba ON ba.book_id = b.book_id
JOIN authors a       ON a.author_id = ba.author_id
LEFT JOIN categories cat ON cat.category_id = b.category_id
WHERE b.title LIKE '%C Prog%' OR a.full_name LIKE '%Ritchie%'
GROUP BY b.book_id, b.title, cat.name;

-- Most borrowed books
SELECT b.title, COUNT(*) AS times_borrowed
FROM transactions t
JOIN book_copies c ON c.copy_id = t.copy_id
JOIN books b       ON b.book_id = c.book_id
GROUP BY b.book_id, b.title
ORDER BY times_borrowed DESC
LIMIT 10;

-- Users with unpaid fines
SELECT u.full_name, SUM(f.amount) AS unpaid_total
FROM fines f
JOIN transactions t ON t.transaction_id = f.transaction_id
JOIN users u        ON u.user_id = t.user_id
WHERE f.paid_on IS NULL
GROUP BY u.user_id, u.full_name;

-- ---------------------------------------------------------------------
-- 5. MYSQL NOTES
-- ---------------------------------------------------------------------
-- This script is intended for MySQL 8.x.
-- Use DATE_ADD(CURDATE(), INTERVAL 14 DAY) for a 14-day loan.
-- Use DATEDIFF() for overdue calculations.
-- The SQLite partial unique index was replaced with a generated column
-- (open_copy_id) and a unique index.
