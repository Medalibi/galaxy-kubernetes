#!/usr/bin/env bash

pvc=$DEPLOYMENT_FOLDER/claim.yaml
cat >$pvc <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs
  resources:
    requests:
      storage: 3600Gi
EOF

kubectl apply -f $pvc

echo "Use galaxy.pvc=$pvc on helm"
