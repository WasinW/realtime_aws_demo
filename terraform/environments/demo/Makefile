# terraform/environments/demo/Makefile
.PHONY: init plan apply destroy clean

init:
	terraform init

plan:
	terraform plan -var-file=.terraform.tfvars

apply:
	terraform apply -var-file=.terraform.tfvars -auto-approve

destroy:
	terraform destroy -var-file=.terraform.tfvars -auto-approve

clean:
	rm -rf .terraform terraform.tfstate* .terraform.lock.hcl

deploy-kafka:
	kubectl create namespace kafka || true
	kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
	kubectl apply -f ../../../kubernetes/kafka/

deploy-debezium:
	kubectl apply -f ../../../kubernetes/debezium/

deploy-all: apply deploy-kafka deploy-debezium
	@echo "Demo deployment complete!"