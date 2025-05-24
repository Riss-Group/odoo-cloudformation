#!/bin/bash

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
VCPU=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" --query "InstanceTypes[0].VCpuInfo.DefaultVCpus" --output text --region "$REGION")
TOTAL_RAM=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" --query "InstanceTypes[0].MemoryInfo.SizeInMiB" --output text --region "$REGION")
TOTAL_RAM_BYTES=$((TOTAL_RAM * 1024 * 1024))

LIMIT_MEMORY_HARD=$((TOTAL_RAM_BYTES / VCPU))
LIMIT_MEMORY_SOFT=$(((TOTAL_RAM - 400) * 1024 * 1024 / VCPU))

ODOO_ROLE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=OdooRole" --query "Tags[0].Value" --output text --region "$REGION")

if [[ "$ODOO_ROLE" == "Cron" ]]; then
    MAX_CRON_THREADS=$VCPU
    WORKERS=$VCPU
else
    MAX_CRON_THREADS=0
    WORKERS=$VCPU
fi

ODOO_CONF="/etc/odoo/odoo.conf"
sed -i "/^max_cron_threads/c\max_cron_threads = $MAX_CRON_THREADS" "$ODOO_CONF"
sed -i "/^workers/c\workers = $WORKERS" "$ODOO_CONF"
sed -i "/^limit_memory_hard/c\limit_memory_hard = $LIMIT_MEMORY_HARD" "$ODOO_CONF"
sed -i "/^limit_memory_soft/c\limit_memory_soft = $LIMIT_MEMORY_SOFT" "$ODOO_CONF"

ODOO_BRANCH=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=OdooBranch" --query "Tags[0].Value" --output text --region "$REGION")
if [[ "$ODOO_BRANCH" == "Dev" ]]; then
    if grep -q '^log_level' "$ODOO_CONF"; then
        sed -i '/^log_level/c\log_level = debug' "$ODOO_CONF"
    else
        echo "log_level = debug" >> "$ODOO_CONF"
    fi
fi

CLOUDWATCH_CONFIG="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
cat <<EOF > $CLOUDWATCH_CONFIG
{
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/odoo/odoo-server.log",
                        "log_group_name": "Odoo${ODOO_BRANCH}Logs",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/auth.log",
                        "log_group_name": "EC2${ODOO_BRANCH}AuthLog",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    }
                ]
            }
        }
    }
}
EOF

# Start CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:$CLOUDWATCH_CONFIG \
  -s

/root/setup_instance_store.sh

cat << 'EOF' > /usr/local/bin/odoo-update
#!/bin/bash

# Check for required arguments
if [ $# -ne 2 ]; then
    echo "Usage: odoo-update <database> <module>"
    exit 1
fi

DB="$1"
MODULE="$2"

# Run the Odoo update as the odoo user
sudo su - odoo -c "/usr/bin/python3 /usr/bin/odoo --config /etc/odoo/odoo.conf -d \"$DB\" -u \"$MODULE\" --xmlrpc-port 8056 --longpolling-port 8057 --stop-after-init"
EOF

chmod +x /usr/local/bin/odoo-update
