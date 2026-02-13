# PostgreSQL Setup & Access Summary (Ubuntu)

This document summarizes the full workflow we performed:
- PostgreSQL service validation
- Database creation
- User creation
- Ownership assignment
- Login validation
- Viewing tables and roles

---

# 1️⃣ Check PostgreSQL Service (OS Level)

```bash
sudo systemctl status postgresql
```

- Ensures the PostgreSQL server process is active.
- If not running:
```bash
sudo systemctl start postgresql
```
- Enable boot:
> systemctl enable postgresql

---
# 2️⃣ Login as PostgreSQL Superuser
```bash
sudo -u postgres psql
```
- Logs into PostgreSQL as the `postgres` role.
- `Superuser Capabilities`
    - Create Databases
    - Create users (roles)
    - Grant privileges
    - Change ownership
    - Full administrative control
---
# 3️⃣ Create a Database
```bash
CREATE DATABASE <db_name>;
```
- It creates a new logical database inside the PostgreSQL cluster.
---

# 4️⃣ Create a User (Role) with Password
```bash
CREATE USER <user_name> WITH ENCRYPTED PASSWORD '<Password>';
```
- It creates a login-enabled role that can authenticate via password.
---

# 5️⃣ Assign Database Ownership (Best Practice)
```bash
ALTER DATABASE <db_name> OWNER TO <user_name>;
```
- It makes `<user_name>` the owner of the `<db_name>` database.
- Owner priviledges include:
    - Creating tables
    - Dropping objects
    - Managing schemas
    - Granting permissions
- This approach is cleaner than manually granting multiple privileges.
- Exist PostgreSQL `Super User` session
---

# 6️⃣ Login Using Application User
```bash
psql -U <user_name> -d <db_name> -h localhost
```
- It validates
    - Password Authentication
    - Database connectivity
    - Correct ownership configuration
- Verify Current logged-in User
> SELECT <current_user>; ------> It will display the current user name.
- **List All Databases**
    > \l
    - It will display:- Database name, Owner, Encoding, Access privileges.
- **List All Users (Roles)**
    >\du
    - It will displays:- Role names, Attributes (Superuser, CreateDB, etc), Role memberships.
    
---
