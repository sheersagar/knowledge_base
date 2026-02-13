# MySQL Setup & Access Summary (Ubuntu)

This document summarizes the full workflow we performed:
- MySQL service validation
- Database creation
- User creation
- Ownership assignment
- Login validation
- Viewing tables and roles

---

# 1️⃣ Check MySQL Service (OS Level)

```bash
sudo systemctl status mysql
```

- Ensures the MySQL server process is active.
- If not running:
```bash
sudo systemctl start mysql
```
- Enable boot:
> systemctl enable mysql

---
# 2️⃣ Login as MySQL Root User.
```bash
sudo mysql
   OR
mysql -u root -p
```
- Logs into MySQL as the `root` user.
- `Root Capabilities`
    - Create Databases
    - Create users.
    - Grant privileges
    - Change ownership
    - Full administrative control
---
# 3️⃣ Create a Database
```bash
CREATE DATABASE <db_name>;
```
- It creates a new logical database inside the MariaDB.
---

# 4️⃣ Create a User with Password
```bash
CREATE USER '<user_name>'@'localhost' IDENTIFIED BY '<Password>';
```
- It creates a login-enabled role that can authenticate via password.
---

# 5️⃣ Grant Database Privileges (Best Practice)
```bash
GRANT ALL PRIVILEGES ON <db_name>.* TO '<user_name>'@'localhost';
FLUSH PRIVILEGES;
```
- It grants full access to `<user_name>` on `<db_name>`
- `FLUSH PRIVILEGES` reloads the privilege tables:
- Exist MariaDB session
>EXIT;
---

# 6️⃣ Login Using Application User
```bash
mysql -u `<user_name>` -p `<db_name>`
```
- It validates
    - Password Authentication
    - Database connectivity
    - Correct privilege configuration
- Verify Current logged-in User
> SELECT DATABASE(); ------> It will display the current user name.
- **List All Databases**
    > SHOW DATABASES;
    - It will display:- Database name.
- **List All Users**
    >SELECT User, Host FROM mysql.user;
    - It will displays:- All users and allowed hosts.
- **Show User Privileges**
    > SHOW GRANTS FOR '<user_name>'@'localhost';
    - It will display privileges assigned to the user.
    
---
