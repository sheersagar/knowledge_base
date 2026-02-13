# MongoDB Setup & Access Summary (Ubuntu)

This document summarizes the full workflow we performed:
- MongoDB service validation
- Database creation
- User creation
- Ownership assignment
- Login validation
- Viewing tables and roles

---

# 1️⃣ Check MongoDB Service (OS Level)

```bash
sudo systemctl status mongod
```

- Ensures the MongoDB server process is active.
- If not running:
```bash
sudo systemctl start mongod
```
- Enable boot:
> systemctl enable mongod

---
# 2️⃣ Login as MongoDB Shell.
```bash
mongosh
```
- Connects to MongoDB shell interface.
---
# 3️⃣ Create/Switch Database
```bash
use <db_name>
```
- It switches to <db_name>.
- MongoDB creates the database only after inserting data.
---

# 4️⃣ Create a User with Password
```bash
CREATE USER '<user_name>'@'localhost' IDENTIFIED BY '<Password>';
```
- It creates a login-enabled role that can authenticate via password.
---

# 5️⃣ Grant Database Privileges (Best Practice)
```bash
db.createUser({
  user: "<user_name>",
  pwd: "<Password>",
  roles: [
    { role: "readWrite", db: "<db_name>" }
  ]
})

```
- It creates a login-enabled user with read/write access to <db_name>.
---

# 6️⃣ Enable Authentication (If Not Enabled)
```bash
sudo vi /etc/mongod.conf
```
- Add:
```bash
security:
    authorization: enabled
```
- Restart:
```bash
sudo systemctl restart mongod
```
- It enables password-based authentication.

---
# 7️⃣ Login Using Application User
```bash
mongosh -u <user_name> -p --authenticationDatabase <db_name>
```
It validates: - Password Authentication, Database connectivity, Correct role configuration.
- **Show All Databases**
    > show dbs;
    - It will display:- All Databases available.
- **Show Collections (Equivalent to Tables)**
    >show collections
    - It will displays:- Collections inside the current database.
- **Insert Test Document**
    > db.test.insertOne({name: "sample});
    - It inserts a test document.
- **View Documents**
    > db.test.find();
    - It displays stored documents.
---
