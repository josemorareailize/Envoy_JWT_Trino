#!/bin/bash

set -e
# Wait for SQL Server to start

echo "Waiting for SQL Server to be ready..."
until /opt/mssql-tools/bin/sqlcmd -S sqlserver -U SA -P 'YourStrong!Passw0rd' -Q "SELECT 1" &>/dev/null
do
  sleep 1
done

echo "SQL Server is ready."
# Run the setup script
/opt/mssql-tools/bin/sqlcmd -S sqlserver -U SA -P 'YourStrong!Passw0rd' -i /sql/setup.sql
