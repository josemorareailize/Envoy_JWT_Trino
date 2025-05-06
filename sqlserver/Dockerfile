FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

# Install dependencies and Microsoft SQL Tools
RUN apt-get update && \
    apt-get install -y curl apt-transport-https gnupg software-properties-common && \
    curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg && \
    install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/ && \
    sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/debian/11/prod bullseye main" > /etc/apt/sources.list.d/mssql-release.list' && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev && \
    ln -sfn /opt/mssql-tools/bin/sqlcmd /usr/bin/sqlcmd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists microsoft.gpg

ENV PATH="${PATH}:/opt/mssql-tools/bin"

USER mssql
