#!/bin/bash
# Shell script to deploy OpenShift 3.6 on Microsoft Azure
# Magnus Glantz, sudo@redhat.com, 2017

OK=0
if [ -f ./deploy.cfg ]; then
	. ./deploy.cfg
	if test -z $RHN_ACCOUNT; then
		OK=1
	elif test -z $OCP_USER; then
		OK=1
	elif test -z $OCP_PASSWORD; then
		OK=1
	elif test -z $SUBSCRIPTION_POOL; then
		OK=1
	elif test -z $LOCATION; then
		OK=1
        elif test -z $RHN_PASSWORD; then
                echo "Please type your red hat password, finish with [enter]:"
                read -s
                RHN_PASSWORD=$REPLY
	fi
else
	OK=1
fi

if [ "$OK" -eq 1 ]; then
	echo "Missing variable values: Edit the deploy.cfg file"
	exit 1
fi

if [ -f ~/.ssh/id_rsa.pub ]; then
	if grep "PUBLIC_SSH_KEY" azuredeploy.parameters.json >/dev/null; then
		PUBLIC_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"
		echo "Your public key at ~/.ssh/id_rsa.pub is:"
		echo "$PUBLIC_SSH_KEY"
	fi
else
        echo "No SSH key found in ~/.ssh/id_rsa.pub. Generating key."
        ssh-keygen
	PUBLIC_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"
	echo "Your key is:"
	echo "$PUBLIC_SSH_KEY"
fi
if test -n "$PUBLIC_SSH_KEY"; then
        echo "Do you want to use this key to access your azure VMs? (y) :"
        read
        if [ "$REPLY" == "y" ]; then
		# copy key to local dir, file path does not expand
                cp ~/.ssh/id_rsa.pub .
		# add a closing quote to where we want to insert the key.
		sed -e ':a' -e 'N' -e '$!ba' -e 's/\(\"PUBLIC_SSH_KEY\"\n\)/\1\"/g' azuredeploy.parameters.json > new
		# copy contents of the public key into the parameters file
                sed  -e '/PUBLIC_SSH_KEY/r id_rsa.pub' new > new1
		# remove dummy value and line break
                sed -e ':a' -e 'N' -e '$!ba' -e 's/PUBLIC_SSH_KEY\"\n//g' new1 > new2
		# clean up temp files
                rm new new1 id_rsa.pub
                mv new2 azuredeploy.parameters.json
        else
                echo "Edit azuredeploy.parameters.json and paste your public ssh key into the value for sshPublicKey."
                exit 1
        fi
fi

# Assign first argument to be Azure Resource Group
GROUP=$1

# Test group variable
if test -z $GROUP; then
	echo "Usuage: $0 <unique name for Azure resource group>"
	exit 1
else
	cat azuredeploy.parameters.json|sed -e "s/REPLACE/$GROUP/g" -e "s/RHN_ACCOUNT/$RHN_ACCOUNT/" -e "s/RHN_PASSWORD/$RHN_PASSWORD/" -e "s/OCP_USER/$OCP_USER/" -e "s/OCP_PASSWORD/$OCP_PASSWORD/" -e "s/SUBSCRIPTION_POOL_ID/$SUBSCRIPTION_POOL/" >azuredeploy.parameters.json.new
	mv azuredeploy.parameters.json.new azuredeploy.parameters.json
fi

echo "Deploying OpenShift Container Platform."

# Create Azure Resource Group
azure group create $GROUP $LOCATION

# Create Keyvault in which we put our SSH private key
azure keyvault create -u ${GROUP}KeyVaultName -g $GROUP -l $LOCATION

# Put SSH private key in key vault
azure keyvault secret set -u ${GROUP}KeyVaultName -s ${GROUP}SecretName --file ~/.ssh/id_rsa

# Enable key vault to be used for deployment
azure keyvault set-policy -u ${GROUP}KeyVaultName --enabled-for-template-deployment true

# Launch deployment of cluster, after this it’s just waiting for it to complete. 
# azuredeploy.parameters.json needs to be populated with valid values first, before you run this.
azure group deployment create --name ${GROUP} --template-file azuredeploy.json -e azuredeploy.parameters.json --resource-group $GROUP --nowait

cat azuredeploy.parameters.json|sed -e "s/$GROUP/REPLACE/g" -e "s/$RHN_ACCOUNT/RHN_ACCOUNT/" -e "s/$RHN_PASSWORD/RHN_PASSWORD/" -e "s/$OCP_USER/OCP_USER/" -e "s/$OCP_PASSWORD/OCP_PASSWORD/" -e "s/$SUBSCRIPTION_POOL/SUBSCRIPTION_POOL_ID/" >azuredeploy.parameters.json.new
mv azuredeploy.parameters.json.new azuredeploy.parameters.json

echo
echo "Deployment initiated. Allow 40-50 minutes for a deployment to succeed."
echo "The cluster will be reachable at https://${GROUP}master.${LOCATION}.cloudapp.azure.com:8443"
echo
echo "Waiting for Bastion host IP to get allocated."

while true; do
	if azure network public-ip show $GROUP bastionpublicip|grep "IP Address"|cut -d':' -f3|grep [0-9] >/dev/null; then
		break
	else
		sleep 5
	fi
done

echo "You can SSH into the cluster by accessing it's bastion host: ssh ${OCP_USER}@$(azure network public-ip show $GROUP bastionpublicip|grep "IP Address"|cut -d':' -f3|grep [0-9])"
echo "Once your SSH key has been distributed to all nodes, you can then jump passwordless from the bastion host to all nodes."
echo "To SSH directly to the master, use port 2200: ssh ${GROUP}master.${LOCATION}.cloudapp.azure.com -p 2200"
echo "For troubleshooting, check out /var/lib/waagent/custom-script/download/[0-1]/stdout or stderr on the nodes"




