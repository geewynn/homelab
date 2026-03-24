.POSIX:

default: apply

namespaces:
	ansible-playbook namespaces.yml

plan: .terraform.lock.hcl
	terraform plan

apply: .terraform.lock.hcl namespaces
	terraform apply -auto-approve