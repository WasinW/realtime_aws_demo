#!/bin/bash
# scripts/setup/99-full-setup.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "Starting full CDC pipeline setup..."

# Run all setup scripts in order
for script in ${SCRIPT_DIR}/[0-9][0-9]-*.sh; do
    if [ "$script" != "${BASH_SOURCE[0]}" ]; then
        echo "Running $(basename ${script})..."
        bash ${script}
    fi
done

echo "Full setup complete!"
echo ""
echo "Next steps:"
echo "1. Run the test producer: python applications/kafka-producer/producer.py --cluster-arn <MSK_CLUSTER_ARN>"
echo "2. Run the test consumer: python applications/kafka-consumer/consumer.py --cluster-arn <MSK_CLUSTER_ARN> --topics oracle.inventory.customers oracle.inventory.products oracle.inventory.orders"
echo "3. Check Redshift materialized views for data"