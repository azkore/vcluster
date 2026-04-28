package pro

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/loft-sh/admin-apis/pkg/licenseapi"
	"github.com/loft-sh/vcluster/pkg/constants"
	"github.com/loft-sh/vcluster/pkg/syncer/synccontext"
	"github.com/loft-sh/vcluster/pkg/util/servicecidr"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	kubeadmconstants "k8s.io/kubernetes/cmd/kubeadm/app/constants"
	"sigs.k8s.io/yaml"
)

var StartPrivateNodesMode = func(ctx *synccontext.ControllerContext) error {
	// skip if we are not in dedicated mode
	if !ctx.Config.PrivateNodes.Enabled {
		return nil
	}

	return ensureKubeadmConfig(ctx)
}

var SyncKubernetesServiceDedicated = func(ctx *synccontext.SyncContext) error {
	// skip if we are not in dedicated mode
	if !ctx.Config.PrivateNodes.Enabled {
		return nil
	}

	return ensureKubernetesService(ctx)
}

var StartKonnectivity = func(ctx *synccontext.ControllerContext) error {
	// skip if we are not in dedicated mode
	if !ctx.Config.PrivateNodes.Enabled {
		return nil
	}

	// Spike build: do not start the pro konnectivity server. Disable
	// controlPlane.advanced.konnectivity.server.enabled in the vCluster values.
	return nil
}

var WithKonnectivity = func(ctx *synccontext.ControllerContext, handler http.Handler) http.Handler {
	return handler
}

var WriteKonnectivityEgressConfig = func() (string, error) {
	return "", NewFeatureError(licenseapi.VirtualClusterProDistroPrivateNodes)
}

type UpgradeOptions struct {
	KubernetesVersion string
	BinariesPath      string
	CNIBinariesPath   string
	BundleRepository  string
}

var UpgradeNode = func(_ context.Context, _ *UpgradeOptions) error {
	return NewFeatureError(licenseapi.VirtualClusterProDistroPrivateNodes)
}

type StandaloneOptions struct {
	Config string
}

var StartStandalone = func(_ context.Context, _ *StandaloneOptions) error {
	return NewFeatureError(licenseapi.Standalone)
}

func ensureKubeadmConfig(ctx *synccontext.ControllerContext) error {
	if ctx.VirtualManager == nil {
		return fmt.Errorf("virtual manager is nil")
	}

	endpoint := ctx.Config.ControlPlane.Endpoint
	if endpoint == "" {
		return fmt.Errorf("controlPlane.endpoint is required for private nodes spike")
	}
	if _, _, err := net.SplitHostPort(endpoint); err != nil {
		return fmt.Errorf("invalid controlPlane.endpoint %q: %w", endpoint, err)
	}

	serviceCIDR, err := servicecidr.GetServiceCIDR(ctx, &ctx.Config.Config, ctx.Config.HostClient, ctx.Config.Name, ctx.Config.HostNamespace)
	if err != nil {
		return fmt.Errorf("get service cidr: %w", err)
	}

	kubernetesVersion := ""
	if ctx.VirtualClusterVersion != nil {
		kubernetesVersion = ctx.VirtualClusterVersion.GitVersion
	}

	clusterConfiguration := map[string]interface{}{
		"apiVersion":           "kubeadm.k8s.io/v1beta4",
		"kind":                 "ClusterConfiguration",
		"clusterName":          "kubernetes",
		"controlPlaneEndpoint": endpoint,
		"certificatesDir":      constants.PKIDir,
		"networking": map[string]string{
			"serviceSubnet": serviceCIDR,
			"podSubnet":     ctx.Config.Networking.PodCIDR,
			"dnsDomain":     ctx.Config.Networking.Advanced.ClusterDomain,
		},
	}
	if kubernetesVersion != "" {
		clusterConfiguration["kubernetesVersion"] = kubernetesVersion
	}

	rawClusterConfiguration, err := yaml.Marshal(clusterConfiguration)
	if err != nil {
		return fmt.Errorf("marshal kubeadm cluster configuration: %w", err)
	}

	configMap := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: metav1.NamespaceSystem, Name: kubeadmconstants.KubeadmConfigConfigMap}
	err = ctx.VirtualManager.GetClient().Get(ctx, key, configMap)
	if apierrors.IsNotFound(err) {
		configMap = &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
			Data: map[string]string{
				"ClusterConfiguration": string(rawClusterConfiguration),
			},
		}
		if err := ctx.VirtualManager.GetClient().Create(ctx, configMap); err != nil {
			return fmt.Errorf("create kubeadm-config configmap: %w", err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get kubeadm-config configmap: %w", err)
	}

	if configMap.Data == nil {
		configMap.Data = map[string]string{}
	}
	configMap.Data["ClusterConfiguration"] = string(rawClusterConfiguration)
	if err := ctx.VirtualManager.GetClient().Update(ctx, configMap); err != nil {
		return fmt.Errorf("update kubeadm-config configmap: %w", err)
	}
	return nil
}

func ensureKubernetesService(ctx *synccontext.SyncContext) error {
	if ctx.VirtualClient == nil {
		return fmt.Errorf("virtual client is nil")
	}

	serviceCIDR, err := servicecidr.GetServiceCIDR(ctx, &ctx.Config.Config, ctx.Config.HostClient, ctx.Config.Name, ctx.Config.HostNamespace)
	if err != nil {
		return fmt.Errorf("get service cidr: %w", err)
	}
	serviceIP, err := firstServiceIP(serviceCIDR)
	if err != nil {
		return err
	}

	service := &corev1.Service{}
	key := types.NamespacedName{Namespace: metav1.NamespaceDefault, Name: "kubernetes"}
	err = ctx.VirtualClient.Get(ctx, key, service)
	if apierrors.IsNotFound(err) {
		service = &corev1.Service{
			ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
			Spec: corev1.ServiceSpec{
				ClusterIP: serviceIP,
				Ports: []corev1.ServicePort{{
					Name:       "https",
					Protocol:   corev1.ProtocolTCP,
					Port:       443,
					TargetPort: intstr.FromInt(6443),
				}},
			},
		}
		if err := ctx.VirtualClient.Create(ctx, service); err != nil {
			return fmt.Errorf("create default/kubernetes service: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("get default/kubernetes service: %w", err)
	} else {
		service.Spec.Ports = []corev1.ServicePort{{
			Name:       "https",
			Protocol:   corev1.ProtocolTCP,
			Port:       443,
			TargetPort: intstr.FromInt(6443),
		}}
		if err := ctx.VirtualClient.Update(ctx, service); err != nil {
			return fmt.Errorf("update default/kubernetes service: %w", err)
		}
	}

	return ensureKubernetesEndpoints(ctx)
}

func ensureKubernetesEndpoints(ctx *synccontext.SyncContext) error {
	host, portString, err := net.SplitHostPort(ctx.Config.ControlPlane.Endpoint)
	if err != nil {
		return fmt.Errorf("invalid controlPlane.endpoint %q: %w", ctx.Config.ControlPlane.Endpoint, err)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// Endpoints require an IP address. For DNS endpoints the service is still
		// useful for in-cluster env var injection, but this spike leaves endpoint
		// routing to direct kubelet/controlPlane.endpoint access.
		return nil
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		return fmt.Errorf("parse controlPlane.endpoint port %q: %w", portString, err)
	}

	endpoints := &corev1.Endpoints{}
	key := types.NamespacedName{Namespace: metav1.NamespaceDefault, Name: "kubernetes"}
	err = ctx.VirtualClient.Get(ctx, key, endpoints)
	if apierrors.IsNotFound(err) {
		endpoints = &corev1.Endpoints{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		setKubernetesEndpointSubsets(endpoints, ip.String(), int32(port))
		if err := ctx.VirtualClient.Create(ctx, endpoints); err != nil {
			return fmt.Errorf("create default/kubernetes endpoints: %w", err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get default/kubernetes endpoints: %w", err)
	}

	setKubernetesEndpointSubsets(endpoints, ip.String(), int32(port))
	if err := ctx.VirtualClient.Update(ctx, endpoints); err != nil {
		return fmt.Errorf("update default/kubernetes endpoints: %w", err)
	}
	return nil
}

func setKubernetesEndpointSubsets(endpoints *corev1.Endpoints, ip string, port int32) {
	endpoints.Subsets = []corev1.EndpointSubset{{
		Addresses: []corev1.EndpointAddress{{IP: ip}},
		Ports: []corev1.EndpointPort{{
			Name:     "https",
			Port:     port,
			Protocol: corev1.ProtocolTCP,
		}},
	}}
}

func firstServiceIP(cidr string) (string, error) {
	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return "", fmt.Errorf("parse service cidr %q: %w", cidr, err)
	}
	if ip.To4() == nil {
		return "", fmt.Errorf("only IPv4 service CIDRs are supported by this private nodes spike, got %q", cidr)
	}

	serviceIP := append(net.IP(nil), ip.To4()...)
	serviceIP[3]++
	if !ipNet.Contains(serviceIP) || strings.EqualFold(serviceIP.String(), ip.String()) {
		return "", fmt.Errorf("could not derive first service IP from %q", cidr)
	}
	return serviceIP.String(), nil
}
