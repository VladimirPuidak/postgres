#!/bin/bash

set -e

# Проверка токена
if [ -z "$HACKATTIC_ACCESS_TOKEN" ]; then
  read -p "Please enter your Hackattic access token: " HACKATTIC_ACCESS_TOKEN  
  echo "Token set successfully!"
fi

# Переменные
HACKATTIC_BASE_URL="https://hackattic.com/challenges/backup_restore"
HACKATTIC_PROBLEM_URL="$HACKATTIC_BASE_URL/problem?access_token=$HACKATTIC_ACCESS_TOKEN"
HACKATTIC_SOLVE_URL="$HACKATTIC_BASE_URL/solve?access_token=$HACKATTIC_ACCESS_TOKEN&playground=1"

POSTGRES_DUMP_ARCHIVE=dump.sql.gz
POSTGRES_IMAGE=postgres:17.6
POSTGRES_HOST=postgresql-host
POSTGRES_DB=hackattic
POSTGRES_USER=postgres
POSTGRES_PASS=password
POSTGRES_QUERY="SELECT ssn FROM criminal_records WHERE status = 'alive';"

#############################################
# Скачивание дампа
#############################################
echo "[1/6] Getting dump..."

json=$(curl -s "$HACKATTIC_PROBLEM_URL")

echo -e "Response from server:\n$json"
echo "$json" | jq -r .dump | base64 -d > $POSTGRES_DUMP_ARCHIVE
#############################################
# Распаковка архива
#############################################
echo "[2/6] unzipping dump"

POSTGRES_SQL_FILE="${POSTGRES_DUMP_ARCHIVE%.gz}"
gunzip -f $POSTGRES_DUMP_ARCHIVE > $POSTGRES_SQL_FILE

echo "Dump was saved into file: $PWD/$POSTGRES_SQL_FILE"
#############################################
# Запуск PostgreSQL 
#############################################
echo "[3/6] Staring PostgreSQL in Docker..."

# Проверяем, есть ли контейнер с таким именем
if docker ps -a --format '{{.Names}}' | grep -Eq "^${POSTGRES_HOST}\$"; then
  echo "Container $POSTGRES_HOST already exists. Removing..."
  docker rm -f "$POSTGRES_HOST"
fi

docker run --name $POSTGRES_HOST -e POSTGRES_PASSWORD=$POSTGRES_PASS -e POSTGRES_DB=$POSTGRES_DB -d $POSTGRES_IMAGE

echo "Waiting for PostgreSQL to be ready..."
until docker exec -i "$POSTGRES_HOST" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  echo "PostgreSQL is not ready yet... waiting 1s"
  sleep 1
done

echo "PostgreSQL is ready!"
#############################################
# Восстановление дампа
#############################################
echo "[4/6] Restoring PostgreSQL dump..."

docker exec -i $POSTGRES_HOST psql -U $POSTGRES_USER -d $POSTGRES_DB < $POSTGRES_SQL_FILE

#############################################
# Запрос в базу
#############################################
echo "[5/6] RUN SQL query..."

ALIVE_SSNS=$(docker exec -i $POSTGRES_HOST psql -U $POSTGRES_USER -d $POSTGRES_DB -t -A -c "$POSTGRES_QUERY")

echo -e "list of allive SSNs:\n$ALIVE_SSNS"
#############################################
# Отправка данных
#############################################
echo "[6/6] Sending data to Hackattic..."

JSON_ARRAY=$(printf '%s\n' "$ALIVE_SSNS" | jq -R . | jq -s .)

PAYLOAD=$(jq -n --argjson arr "$JSON_ARRAY" '{alive_ssns: $arr}')

RESPONSE=$(curl -s -X POST "$HACKATTIC_SOLVE_URL" -H "Content-Type: application/json" -d "$PAYLOAD")

echo "$RESPONSE"
#############################################
# Очистка ресурсов
#############################################
echo "[7/7] Cleaning up..."

echo "Removing PostgreSQL container..."
docker rm -f $POSTGRES_HOST

echo "Removing SQL file..."
rm $POSTGRES_SQL_FILE
