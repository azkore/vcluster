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
	rbacv1 "k8s.io/api/rbac/v1"
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

	if err := ensureKubeadmConfig(ctx); err != nil {
		return err
	}
	if err := ensureKubeletConfig(ctx); err != nil {
		return err
	}
	if err := ensureBootstrapRBAC(ctx); err != nil {
		return err
	}
	return ensureKubeProxyRBAC(ctx)
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

	// Proof-of-concept build: do not start the pro konnectivity server. Disable
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

func ensureKubeletConfig(ctx *synccontext.ControllerContext) error {
	if ctx.VirtualManager == nil {
		return fmt.Errorf("virtual manager is nil")
	}

	serviceCIDR, err := servicecidr.GetServiceCIDR(ctx, &ctx.Config.Config, ctx.Config.HostClient, ctx.Config.Name, ctx.Config.HostNamespace)
	if err != nil {
		return fmt.Errorf("get service cidr: %w", err)
	}
	clusterDNS, err := serviceIPWithOffset(serviceCIDR, 10)
	if err != nil {
		return fmt.Errorf("derive cluster dns service ip: %w", err)
	}

	clusterDomain := ctx.Config.Networking.Advanced.ClusterDomain
	if clusterDomain == "" {
		clusterDomain = "cluster.local"
	}

	kubeletConfiguration := map[string]interface{}{
		"apiVersion": "kubelet.config.k8s.io/v1beta1",
		"kind":       "KubeletConfiguration",
		"authentication": map[string]interface{}{
			"anonymous": map[string]bool{"enabled": false},
			"webhook": map[string]interface{}{
				"enabled":  true,
				"cacheTTL": "0s",
			},
			"x509": map[string]string{"clientCAFile": "/etc/kubernetes/pki/ca.crt"},
		},
		"authorization": map[string]interface{}{
			"mode": "Webhook",
			"webhook": map[string]string{
				"cacheAuthorizedTTL":   "0s",
				"cacheUnauthorizedTTL": "0s",
			},
		},
		"cgroupDriver":       "systemd",
		"clusterDNS":         []string{clusterDNS},
		"clusterDomain":      clusterDomain,
		"failSwapOn":         false,
		"healthzBindAddress": "127.0.0.1",
		"healthzPort":        int32(10248),
		"memorySwap":         map[string]interface{}{},
		"rotateCertificates": true,
		"staticPodPath":      "/etc/kubernetes/manifests",
	}
	rawKubeletConfiguration, err := yaml.Marshal(kubeletConfiguration)
	if err != nil {
		return fmt.Errorf("marshal kubelet configuration: %w", err)
	}

	return ensureConfigMap(ctx, metav1.NamespaceSystem, kubeadmconstants.KubeletBaseConfigurationConfigMap, map[string]string{
		kubeadmconstants.KubeletBaseConfigurationConfigMapKey: string(rawKubeletConfiguration),
	})
}

func ensureBootstrapRBAC(ctx *synccontext.ControllerContext) error {
	if ctx.VirtualManager == nil {
		return fmt.Errorf("virtual manager is nil")
	}

	bootstrapSubjects := []rbacv1.Subject{
		{Kind: rbacv1.GroupKind, APIGroup: rbacv1.GroupName, Name: "system:bootstrappers"},
		{Kind: rbacv1.GroupKind, APIGroup: rbacv1.GroupName, Name: kubeadmconstants.NodeBootstrapTokenAuthGroup},
	}

	if err := ensureRole(ctx, metav1.NamespaceSystem, "vcluster-private-nodes-bootstrap-config-reader", []rbacv1.PolicyRule{{
		APIGroups:     []string{""},
		Resources:     []string{"configmaps"},
		ResourceNames: []string{kubeadmconstants.KubeadmConfigConfigMap, kubeadmconstants.KubeletBaseConfigurationConfigMap, kubeadmconstants.KubeProxyConfigMap},
		Verbs:         []string{"get"},
	}}); err != nil {
		return err
	}
	if err := ensureRoleBinding(ctx, metav1.NamespaceSystem, "vcluster-private-nodes-bootstrap-config-reader", rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "Role", Name: "vcluster-private-nodes-bootstrap-config-reader"}, bootstrapSubjects); err != nil {
		return err
	}

	if err := ensureClusterRole(ctx, "vcluster-private-nodes-bootstrap-node-reader", []rbacv1.PolicyRule{{
		APIGroups: []string{""},
		Resources: []string{"nodes"},
		Verbs:     []string{"get"},
	}}); err != nil {
		return err
	}
	if err := ensureClusterRoleBinding(ctx, "vcluster-private-nodes-bootstrap-node-reader", rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: "vcluster-private-nodes-bootstrap-node-reader"}, bootstrapSubjects); err != nil {
		return err
	}

	for _, binding := range []struct {
		name     string
		roleName string
		subjects []rbacv1.Subject
	}{
		{
			name:     "vcluster-private-nodes-create-csrs-for-bootstrapping",
			roleName: "system:node-bootstrapper",
			subjects: bootstrapSubjects,
		},
		{
			name:     "vcluster-private-nodes-auto-approve-csrs-for-bootstrappers",
			roleName: "system:certificates.k8s.io:certificatesigningrequests:nodeclient",
			subjects: bootstrapSubjects,
		},
		{
			name:     "vcluster-private-nodes-auto-approve-renewals-for-nodes",
			roleName: "system:certificates.k8s.io:certificatesigningrequests:selfnodeclient",
			subjects: []rbacv1.Subject{{Kind: rbacv1.GroupKind, APIGroup: rbacv1.GroupName, Name: "system:nodes"}},
		},
	} {
		if err := ensureClusterRoleBinding(ctx, binding.name, rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: binding.roleName}, binding.subjects); err != nil {
			return err
		}
	}

	return nil
}

func ensureKubeProxyRBAC(ctx *synccontext.ControllerContext) error {
	if ctx.VirtualManager == nil {
		return fmt.Errorf("virtual manager is nil")
	}

	serviceAccount := &corev1.ServiceAccount{}
	key := types.NamespacedName{Namespace: metav1.NamespaceSystem, Name: "kube-proxy"}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, serviceAccount)
	if apierrors.IsNotFound(err) {
		serviceAccount = &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		if err := ctx.VirtualManager.GetClient().Create(ctx, serviceAccount); err != nil {
			return fmt.Errorf("create kube-proxy serviceaccount: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("get kube-proxy serviceaccount: %w", err)
	}

	return ensureClusterRoleBinding(ctx, "vcluster-private-nodes-kube-proxy", rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: "system:node-proxier"}, []rbacv1.Subject{{
		Kind:      rbacv1.ServiceAccountKind,
		Name:      "kube-proxy",
		Namespace: metav1.NamespaceSystem,
	}})
}

func ensureConfigMap(ctx *synccontext.ControllerContext, namespace, name string, data map[string]string) error {
	configMap := &corev1.ConfigMap{}
	key := types.NamespacedName{Namespace: namespace, Name: name}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, configMap)
	if apierrors.IsNotFound(err) {
		configMap = &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, Data: data}
		if err := ctx.VirtualManager.GetClient().Create(ctx, configMap); err != nil {
			return fmt.Errorf("create %s/%s configmap: %w", namespace, name, err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get %s/%s configmap: %w", namespace, name, err)
	}

	configMap.Data = data
	if err := ctx.VirtualManager.GetClient().Update(ctx, configMap); err != nil {
		return fmt.Errorf("update %s/%s configmap: %w", namespace, name, err)
	}
	return nil
}

func ensureRole(ctx *synccontext.ControllerContext, namespace, name string, rules []rbacv1.PolicyRule) error {
	role := &rbacv1.Role{}
	key := types.NamespacedName{Namespace: namespace, Name: name}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, role)
	if apierrors.IsNotFound(err) {
		role = &rbacv1.Role{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, Rules: rules}
		if err := ctx.VirtualManager.GetClient().Create(ctx, role); err != nil {
			return fmt.Errorf("create %s/%s role: %w", namespace, name, err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get %s/%s role: %w", namespace, name, err)
	}

	role.Rules = rules
	if err := ctx.VirtualManager.GetClient().Update(ctx, role); err != nil {
		return fmt.Errorf("update %s/%s role: %w", namespace, name, err)
	}
	return nil
}

func ensureRoleBinding(ctx *synccontext.ControllerContext, namespace, name string, roleRef rbacv1.RoleRef, subjects []rbacv1.Subject) error {
	roleBinding := &rbacv1.RoleBinding{}
	key := types.NamespacedName{Namespace: namespace, Name: name}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, roleBinding)
	if apierrors.IsNotFound(err) {
		roleBinding = &rbacv1.RoleBinding{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, RoleRef: roleRef, Subjects: subjects}
		if err := ctx.VirtualManager.GetClient().Create(ctx, roleBinding); err != nil {
			return fmt.Errorf("create %s/%s rolebinding: %w", namespace, name, err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get %s/%s rolebinding: %w", namespace, name, err)
	}

	roleBinding.Subjects = subjects
	if roleBinding.RoleRef != roleRef {
		if err := ctx.VirtualManager.GetClient().Delete(ctx, roleBinding); err != nil {
			return fmt.Errorf("delete %s/%s rolebinding with immutable roleRef: %w", namespace, name, err)
		}
		roleBinding = &rbacv1.RoleBinding{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, RoleRef: roleRef, Subjects: subjects}
		if err := ctx.VirtualManager.GetClient().Create(ctx, roleBinding); err != nil {
			return fmt.Errorf("recreate %s/%s rolebinding: %w", namespace, name, err)
		}
		return nil
	}
	if err := ctx.VirtualManager.GetClient().Update(ctx, roleBinding); err != nil {
		return fmt.Errorf("update %s/%s rolebinding: %w", namespace, name, err)
	}
	return nil
}

func ensureClusterRole(ctx *synccontext.ControllerContext, name string, rules []rbacv1.PolicyRule) error {
	clusterRole := &rbacv1.ClusterRole{}
	key := types.NamespacedName{Name: name}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, clusterRole)
	if apierrors.IsNotFound(err) {
		clusterRole = &rbacv1.ClusterRole{ObjectMeta: metav1.ObjectMeta{Name: key.Name}, Rules: rules}
		if err := ctx.VirtualManager.GetClient().Create(ctx, clusterRole); err != nil {
			return fmt.Errorf("create %s clusterrole: %w", name, err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get %s clusterrole: %w", name, err)
	}

	clusterRole.Rules = rules
	if err := ctx.VirtualManager.GetClient().Update(ctx, clusterRole); err != nil {
		return fmt.Errorf("update %s clusterrole: %w", name, err)
	}
	return nil
}

func ensureClusterRoleBinding(ctx *synccontext.ControllerContext, name string, roleRef rbacv1.RoleRef, subjects []rbacv1.Subject) error {
	clusterRoleBinding := &rbacv1.ClusterRoleBinding{}
	key := types.NamespacedName{Name: name}
	err := ctx.VirtualManager.GetClient().Get(ctx, key, clusterRoleBinding)
	if apierrors.IsNotFound(err) {
		clusterRoleBinding = &rbacv1.ClusterRoleBinding{ObjectMeta: metav1.ObjectMeta{Name: key.Name}, RoleRef: roleRef, Subjects: subjects}
		if err := ctx.VirtualManager.GetClient().Create(ctx, clusterRoleBinding); err != nil {
			return fmt.Errorf("create %s clusterrolebinding: %w", name, err)
		}
		return nil
	} else if err != nil {
		return fmt.Errorf("get %s clusterrolebinding: %w", name, err)
	}

	clusterRoleBinding.Subjects = subjects
	if clusterRoleBinding.RoleRef != roleRef {
		if err := ctx.VirtualManager.GetClient().Delete(ctx, clusterRoleBinding); err != nil {
			return fmt.Errorf("delete %s clusterrolebinding with immutable roleRef: %w", name, err)
		}
		clusterRoleBinding = &rbacv1.ClusterRoleBinding{ObjectMeta: metav1.ObjectMeta{Name: key.Name}, RoleRef: roleRef, Subjects: subjects}
		if err := ctx.VirtualManager.GetClient().Create(ctx, clusterRoleBinding); err != nil {
			return fmt.Errorf("recreate %s clusterrolebinding: %w", name, err)
		}
		return nil
	}
	if err := ctx.VirtualManager.GetClient().Update(ctx, clusterRoleBinding); err != nil {
		return fmt.Errorf("update %s clusterrolebinding: %w", name, err)
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
	ip, ok, err := resolveEndpointIP(host)
	if err != nil {
		return err
	} else if !ok {
		// Endpoints require an IP address. If DNS is not resolvable yet, keep the
		// service for in-cluster env var injection and let nodes use the external
		// controlPlane.endpoint directly.
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

func resolveEndpointIP(host string) (net.IP, bool, error) {
	ip := net.ParseIP(host)
	if ip != nil {
		if ip.To4() == nil {
			return nil, false, fmt.Errorf("only IPv4 controlPlane.endpoint addresses are supported by this private nodes proof of concept, got %q", host)
		}
		return ip.To4(), true, nil
	}

	ips, err := net.LookupIP(host)
	if err != nil {
		return nil, false, nil
	}
	for _, ip := range ips {
		if ip.To4() != nil {
			return ip.To4(), true, nil
		}
	}
	return nil, false, nil
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
	return serviceIPWithOffset(cidr, 1)
}

func serviceIPWithOffset(cidr string, offset byte) (string, error) {
	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return "", fmt.Errorf("parse service cidr %q: %w", cidr, err)
	}
	if ip.To4() == nil {
		return "", fmt.Errorf("only IPv4 service CIDRs are supported by this private nodes proof of concept, got %q", cidr)
	}

	serviceIP := append(net.IP(nil), ip.To4()...)
	serviceIP[3] += offset
	if !ipNet.Contains(serviceIP) || strings.EqualFold(serviceIP.String(), ip.String()) {
		return "", fmt.Errorf("could not derive service IP offset %d from %q", offset, cidr)
	}
	return serviceIP.String(), nil
}
