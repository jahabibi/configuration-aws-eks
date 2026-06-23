import models.io.upbound.awsm.v1beta1 as awsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1


_items = [
    metav1alpha1.E2ETest{
        metadata.name: "eks"
        spec= {
            crossplane.autoUpgrade.channel: "None"
            crossplane.version = "2.0.2-up.5"
            defaultConditions: ["Ready"]
            manifests: [
                platformawsv1alpha1.Compute{
                    metadata = {
                        name = "configuration-aws-eks"
                        namespace = "default"
                    }
                    spec = {
                        parameters = {
                            id = "configuration-aws-eks"
                            region = "us-west-2"
                            engine = "eks"
                            nodes = {
                                count = 1
                                size = "small"
                            }
                            # standalone: resolve subnets from the Network's
                            # published status via extra-resources
                            networkRef = {
                                id = "configuration-aws-eks"
                            }
                        }
                    }
                }
                platformawsv1alpha1.Network{
                    metadata = {
                        name = "configuration-aws-eks"
                        namespace = "default"
                    }
                    spec = {
                        parameters = {
                            region = "us-west-2"
                        }
                    }
                }

            ]
            extraResources = [
                # Define the provider configuration
                awsv1beta1.ProviderConfig{
                    metadata = {
                        name = "default"
                        namespace = "default"
                    }
                    spec = {
                        credentials = {
                            source = "Upbound"
                            upbound = {
                                webIdentity = {
                                    roleARN = "arn:aws:iam::609897127049:role/solutions-e2e-provider-aws"
                                }
                            }
                        }
                    }
                }
            ]
            skipDelete: False
            timeoutSeconds: 4500
        }
    }
]
items= _items
