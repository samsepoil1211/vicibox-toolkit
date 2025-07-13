#!/bin/bash

echo "=== VICIdial User & Phone Creator (Safe Mode, Start from 3001) ==="

# Prompt for counts
read -p "🔢 Enter number of users to create: " NUM_USERS
read -p "🔢 Enter number of phones to create: " NUM_PHONES

# MySQL access
DB_USER="cron"
DB_PASS="1234"
DB_NAME="asterisk"

# Detect server IP
SERVER_IP=$(mysql -u$DB_USER -p$DB_PASS -N -B -e "SELECT server_ip FROM servers WHERE active='Y' LIMIT 1;" $DB_NAME)
if [[ -z "$SERVER_IP" ]]; then
  echo "❌ No active server found!"
  exit 1
fi
echo "✅ Detected standalone server IP: $SERVER_IP"

# Auto-detect starting user ID (>= 3001)
START_USER_ID=$(mysql -u$DB_USER -p$DB_PASS -N -B -e "SELECT MAX(CAST(user AS UNSIGNED)) FROM vicidial_users WHERE user RLIKE '^[0-9]+$';" $DB_NAME)
START_USER_ID=$(( START_USER_ID < 3000 ? 3001 : START_USER_ID + 1 ))

# Auto-detect starting extension ID (>= 3001)
START_EXT_ID=$(mysql -u$DB_USER -p$DB_PASS -N -B -e "SELECT MAX(CAST(extension AS UNSIGNED)) FROM phones WHERE extension RLIKE '^[0-9]+$';" $DB_NAME)
START_EXT_ID=$(( START_EXT_ID < 3000 ? 3001 : START_EXT_ID + 1 ))

# Create users
echo "👤 Creating $NUM_USERS users starting from ID $START_USER_ID..."
for ((i=0; i<NUM_USERS; i++)); do
  USER_ID=$((START_USER_ID + i))
  EXISTS=$(mysql -u$DB_USER -p$DB_PASS -N -B -e "SELECT COUNT(*) FROM vicidial_users WHERE user='$USER_ID';" $DB_NAME)
  if [[ "$EXISTS" -eq 0 ]]; then
    mysql -u$DB_USER -p$DB_PASS $DB_NAME <<EOF
INSERT INTO vicidial_users (user, pass, full_name, user_level, user_group, active)
VALUES ('$USER_ID', '1234', 'AutoUser$USER_ID', '1', 'ADMIN', 'Y');
EOF
    echo "✅ Created user $USER_ID"
  else
    echo "⚠️  User $USER_ID already exists, skipping"
  fi
done

# Create phones
echo "📞 Creating $NUM_PHONES phones starting from extension $START_EXT_ID..."
for ((i=0; i<NUM_PHONES; i++)); do
  EXT=$((START_EXT_ID + i))
  EXISTS=$(mysql -u$DB_USER -p$DB_PASS -N -B -e "SELECT COUNT(*) FROM phones WHERE extension='$EXT' AND server_ip='$SERVER_IP';" $DB_NAME)
  if [[ "$EXISTS" -eq 0 ]]; then
    mysql -u$DB_USER -p$DB_PASS $DB_NAME <<EOF
INSERT INTO phones (
  extension, dialplan_number, voicemail_id, login, pass,
  server_ip, protocol, phone_type, status, active
) VALUES (
  '$EXT', '$EXT', '$EXT', '$EXT', '1234',
  '$SERVER_IP', 'SIP', 'agent', 'ACTIVE', 'Y'
);
EOF
    echo "✅ Created phone $EXT on server $SERVER_IP"
  else
    echo "⚠️  Phone $EXT already exists on $SERVER_IP, skipping"
  fi
done

echo "🎉 User and phone creation complete. Starting from clean ID above 3001!"
