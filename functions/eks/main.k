import models.io.upbound.awsm.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.awsm.iam.v1beta1 as iamv1beta1
import models.io.crossplane.kubernetesm.v1alpha1 as k8sv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import regex
import crypto

oxr = option("params").oxr # observed composite resource
_ocds = option("params").ocds # observed composed resources
_dxr = option("params").dxr # desired composite resource
dcds = option("params").dcds # desired composed resources

params = oxr.spec.parameters

xrName = oxr.metadata.name
uid = oxr.metadata.uid or ""

# Inter-domain wiring: subnet placement comes from the Network domain's
# published status.zones[]. Nested under Cluster the parent injects subnetIds;
# standalone we fetch the referenced Network via extra-resources and read its
# status. Either way: no provider-MR label selectors.
_extra = option("params").extraResources or {}
_networkXRs = _extra?["network"] or []
_networkXR = _networkXRs[0] if len(_networkXRs) > 0 else {}
_networkStatus = _networkXR?.Resource?.status or _networkXR?.status or {}
_zones = _networkStatus?.zones or []
_publicSubnetIds = params?.subnetIds?.public or [z.publicSubnetId for z in _zones if z?.publicSubnetId]
_privateSubnetIds = params?.subnetIds?.private or [z.privateSubnetId for z in _zones if z?.privateSubnetId]
_networkRefId = params?.networkRef?.id or ""

# reclaimPolicy (PV vocabulary) -> Crossplane v2 management policies. The
# consumer contract speaks Kubernetes; only this line speaks Crossplane.
_reclaimPolicy = params?.reclaimPolicy or "Delete"
_managementPolicies = ["Create", "Observe", "Update", "LateInitialize"] if _reclaimPolicy == "Retain" else ["*"]
_providerConfigName = params?.overrides?.providerConfigName or "default"

# Node capacity intent -> instance type (L3 mapping; consumers express size).
_sizeToInstanceType = {small = "t3.small", medium = "t3.large", large = "t3.xlarge"}
_instanceType = _sizeToInstanceType[params?.nodes?.size or "small"]

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

ready = lambda o: any, statusPath = "atProvider" -> bool {
    status = o?.Resource?.status
    objstatus = status?.conditions or []
    len(objstatus) > 0 and all_true([c.status == "True" for c in objstatus]) and status and statusPath in status
}

exists: (str) -> bool = lambda o: str -> bool {
    resource = get(_ocds, o, {})
    resource != {}
}

get = lambda x: any, y: str, d: any -> any {
    """
            Get an item from a dictionary using a dot separated path.
            If the item is not found, return a default value.
            """
    p = regex.split(y, "\.")
    c = p[0]
    y = ".".join(p[1::])
    x[c] if len(p) == 1 and c in x else d if c not in x else get(x[c], y, d)
}

_defaults = {
    managementPolicies = _managementPolicies
    providerConfigRef = {
        kind = "ProviderConfig"
        name = _providerConfigName
    }
}

_items = []

_items += [
    iamv1beta1.Role {
        metadata = _metadata("controlplaneRole") | {
            labels: {
                role = "controlplane"
            }
        }
        spec: _defaults | {
            forProvider = {
                forceDetachPolicies = True
                managedPolicyArns = [
                    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
                ]
                assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "eks.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
"""
            }
        }
    }
    eksv1beta1.Cluster {
        metadata = _metadata("kubernetesCluster")
        spec: _defaults | {
            forProvider = {
                region = params.region
                version = params.version
                # L3 default — access mode is an implementation detail, not a
                # consumer-facing knob.
                accessConfig = {
                    authenticationMode = "API_AND_CONFIG_MAP"
                    bootstrapClusterCreatorAdminPermissions = True
                }
                roleArnSelector = {
                    matchControllerRef = True
                    matchLabels = {
                        role = "controlplane"
                    }
                }
                vpcConfig = {
                    endpointPrivateAccess = True
                    # Explicit subnet IDs from Network.status.zones (injected by
                    # the parent); replaces provider-MR subnetIdSelector coupling.
                    subnetIds = _publicSubnetIds
                }
            }
        }
    }
]

clusterSecurityGroupId = _ocds?.kubernetesCluster?.Resource?.status?.atProvider?.vpcConfig?.clusterSecurityGroupId or False
if clusterSecurityGroupId:
    _items += [
        ec2v1beta1.SecurityGroup {
            metadata = {
                annotations = {
                    **_metadata("clusterSecurityGroupImport").annotations
                    "crossplane.io/external-name" = clusterSecurityGroupId
                }
            }
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    tags = {
                        "eks.aws.platform.upbound.io/discovery" = params.id
                    }
                }
            }
        }
    ]

if ready(get(_ocds, "kubernetesCluster", "")) or exists("kubernetesClusterAuth"):
    _items += [
        eksv1beta1.ClusterAuth {
            metadata = _metadata("kubernetesClusterAuth")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    clusterNameSelector.matchControllerRef = True
                }
                writeConnectionSecretToRef = {
                    name = "{}-ekscluster".format(uid)
                }
            }
        }
    ]

_items += [
    iamv1beta1.Role {
        metadata = _metadata("nodegroupRole") | {
            labels = {
                role = "nodegroup"
            }
        }
        spec: _defaults | {
            forProvider = {
                forceDetachPolicies = True
                managedPolicyArns = [
                    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
                    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
                    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
                    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
                ]
                assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
"""
            }
        }
    }
]

nodeCount = params?.nodes?.count or ""
instanceType = _instanceType

if ready(get(_ocds, "vpc-cni-addon", "")) or exists("nodeGroupPublic"):
    _items += [
        eksv1beta1.NodeGroup {
            metadata = _metadata("nodeGroupPublic")
            spec: _defaults | {
                initProvider = {
                    scalingConfig = {
                        desiredSize = nodeCount
                    }
                }
                forProvider = {
                    region = params.region
                    clusterNameSelector.matchControllerRef = True
                    nodeRoleArnSelector = {
                        matchControllerRef = True
                        matchLabels = {
                            role = "nodegroup"
                        }
                    }
                    scalingConfig = {
                        maxSize = 100
                        minSize = 1
                    }
                    instanceTypes = [instanceType]
                    subnetIds = _publicSubnetIds
                }
            }
        }
    ]

# Cluster-admin grants: one AccessEntry + AccessPolicyAssociation per principal
# in adminPrincipals. "Who can administer this cluster" is consumer intent; the
# access-entry wiring is this L3 detail.
_adminPrincipals = params?.adminPrincipals or []
_accessFor = lambda p: str -> [any] {
    [
        eksv1beta1.AccessEntry {
            # hash-named to force recreate when the principal changes
            metadata = _metadata(crypto.sha256("accessEntry-{}".format(p)))
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    clusterNameSelector = {
                        matchControllerRef = True
                    }
                    type = "STANDARD"
                    principalArn = p
                }
            }
        }
        eksv1beta1.AccessPolicyAssociation {
            metadata = _metadata(crypto.sha256("accessPolicyAssociation-{}".format(p)))
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    accessScope: {
                        type: "cluster"
                    }
                    clusterNameSelector = {
                        matchControllerRef = True
                    }
                    policyArn: "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
                    principalArnSelector = {
                        matchControllerRef = True
                    }
                }
            }
        }
    ]
}
_items += [e for p in _adminPrincipals for e in _accessFor(p)]

if ready(get(_ocds, "kubernetesClusterAuth", {})) or exists("vpc-cni-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("vpc-cni-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "vpc-cni"
                    clusterNameSelector.matchControllerRef = True
                    # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
                    configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
                }
            }
        }
    ]

_items += [
    iamv1beta1.Role {
        metadata = _metadata("ebsCSIDriverRole") | {
            labels = {
                role = "ebs-csi-driver"
            }
        }
        spec: _defaults | {
            forProvider = {
                forceDetachPolicies = True
                managedPolicyArns = [
                    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
                ]
                assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
"""
            }
        }
    }
]

_items += [
    eksv1beta1.PodIdentityAssociation {
        metadata = _metadata("ebsCSIDriverPodIdentityAssociation")
        spec: _defaults | {
            forProvider = {
                region = params.region
                clusterNameSelector.matchControllerRef = True
                namespace = "kube-system"
                serviceAccount = "ebs-csi-controller-sa"
                roleArnSelector = {
                    matchControllerRef = True
                    matchLabels = {
                        role = "ebs-csi-driver"
                    }
                }
            }
        }
    }
]

if (ready(get(_ocds, "ebsCSIDriverPodIdentityAssociation", "")) and ready(get(_ocds, "nodeGroupPublic", ""))) or exists("aws-ebs-csi-driver-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("aws-ebs-csi-driver-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "aws-ebs-csi-driver"
                    clusterNameSelector.matchControllerRef = True
                    configurationValues = '{"defaultStorageClass": {"enabled": true}}'
                }
            }
        }
    ]

if ready(get(_ocds, "nodeGroupPublic", "")) or exists("eks-pod-identity-agent"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("eks-pod-identity-agent-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "eks-pod-identity-agent"
                    clusterNameSelector.matchControllerRef = True
                }
            }
        }
    ]

_items += [
    k8sv1alpha1.ProviderConfig {
        metadata = {
            name = params.id
            generateName = "{}-".format(params.id)
            annotations = {
                **_metadata("providerConfig-kubernetes").annotations
                "krm.kcl.dev/ready": "True"
            }
        }
        spec.credentials = {
            secretRef = {
                name = "{}-ekscluster".format(uid)
                namespace = oxr.metadata.namespace
                key = "kubeconfig"
            }
            source = "Secret"
        }
    }
]

_items += [
    helmv1beta1.ProviderConfig {
        metadata = {
            name = params.id
            generateName = "{}-".format(params.id)
            annotations = {
                **_metadata("providerConfig-helm").annotations
                "krm.kcl.dev/ready": "True"
            }
        }
        spec.credentials = {
            secretRef = {
                name = "{}-ekscluster".format(uid)
                namespace = oxr.metadata.namespace
                key = "kubeconfig"
            }
            source = "Secret"
        }
    }
]

_items += [{
    apiVersion: "meta.krm.kcl.dev/v1alpha1"
    kind: "CompositeConnectionDetails"
    if "kubernetesClusterAuth" in _ocds:
        data: {
            kubeconfig = _ocds?.kubernetesClusterAuth?.ConnectionDetails?.kubeconfig
        }
    else:
        data: {}
}]

# Structured status — the inter-domain contract consumed by Identity & Ingress.
_clusterMR = _ocds?["kubernetesCluster"]?.Resource or {}
_vpcConfig = _clusterMR?.status?.atProvider?.vpcConfig or {}
_dxr = _dxr | {
    status: {
        clusterName = _clusterMR?.metadata?.annotations?["crossplane.io/external-name"] or _clusterMR?.metadata?.name
        if _vpcConfig?.vpcId:
            networkId = _vpcConfig.vpcId
        if _vpcConfig?.clusterSecurityGroupId:
            clusterSecurityGroupId = _vpcConfig.clusterSecurityGroupId
        connectionConfigName = params.id
        region = params.region
        version = params.version
    }
}

_items += [_dxr]

# Standalone: request the referenced Network so subnet placement can be read
# from its published status.zones[] (skipped when the parent injected subnetIds).
if _networkRefId and not params?.subnetIds?.public:
    _items += [{
        apiVersion: "meta.krm.kcl.dev/v1alpha1"
        kind: "ExtraResources"
        requirements: {
            "network": {
                apiVersion: "aws.platform.upbound.io/v1alpha1"
                kind: "Network"
                matchName: _networkRefId
                # Network is a namespaced XR; matchNamespace scopes the lookup.
                # Requires function-kcl >= v0.11.6 (matchNamespace support) — older
                # runtimes silently drop it, querying cluster-scoped and finding nothing.
                matchNamespace: oxr.metadata.namespace
            }
        }
    }]

items = _items