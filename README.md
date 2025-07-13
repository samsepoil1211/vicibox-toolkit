# VICIdial User & Phone Auto-Creator (Standalone Server Edition)

🚀 This script allows you to **automatically create VICIdial users and phones** in bulk on a **standalone ViciBox 8+ server**.  
It ensures:
- No duplicate IDs
- Phones show as **ACTIVE** in the Admin UI
- Users are grouped under `ADMIN` with level `1`

---

## 📦 Features

✅ Safe from duplicate insert errors  
✅ Auto-detects next available User ID & Phone Extension  
✅ Cleanly formatted and color-coded Bash prompts  
✅ Compatible with **ViciBox 8/9** using **MySQL & AstGUIclient schema**

---

## 📁 File Included

- `create_vicidial_users_phones.sh`: Main automation script

---

## 🛠️ Requirements

- ViciBox 8.x or 9.x (Standalone Mode)
- Root or `sudo` access to shell
- MySQL `cron` user (default password assumed `1234`)
- `vicidial_users` and `phones` tables configured properly

---
Run the script

bash
Copy
Edit

## 🚀 How to Use

1. **SSH into your ViciBox server**

2. **Download the script**
```bash
wget https://github.com/your-repo/create_vicidial_users_phones.sh
chmod +x create_vicidial_users_phones.sh
```
3. **Run the script**
```bash
./create_vicidial_users_phones.sh
```

4. **Follow the prompt**
```bash
🔢 Enter number of users to create: 10
🔢 Enter number of phones to create: 10
```

# Sample Output 

```bash
=== VICIdial User & Phone Creator (Safe Mode, Start from 3001) ===
✅ Detected standalone server IP: 192.168.1.100
👤 Creating 10 users starting from ID 3001...
✅ Created user 3001
✅ Created user 3002
...
📞 Creating 10 phones starting from extension 3001...
✅ Created phone 3001 on server 192.168.1.100
✅ Created phone 3002 on server 192.168.1.100
...
🎉 User and phone creation complete. Starting from clean ID above 3001!

