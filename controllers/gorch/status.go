package gorch

import (
	"context"
	gorchv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/gorch/v1alpha1"
	"github.com/trustyai-explainability/trustyai-service-operator/controllers/utils"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var (
	generatorReady  bool
	deploymentReady bool
	routeReady      bool
)

const (
	AutoConfigFailed = "AutoConfigFailed"
)

<<<<<<< HEAD
const (
	PhaseProgressing = "Progressing"
	PhaseReady       = "Ready"
)

const (
	ReconcileFailed           = "ReconcileFailed"
	ReconcileInit             = "ReconcileInit"
	ReconcileCompleted        = "ReconcileCompleted"
	ReconcileCompletedMessage = "Reconcile completed successfully"
	ReconcileFailedMessage    = "Reconcile failed"
)

func SetStatusCondition(conditions *[]gorchv1alpha1.Condition, newCondition gorchv1alpha1.Condition) bool {
	if conditions == nil {
		conditions = &[]gorchv1alpha1.Condition{}
	}
	existingCondition := GetStatusCondition(*conditions, newCondition.Type)
	if existingCondition == nil {
		newCondition.LastTransitionTime = metav1.NewTime(time.Now())
		*conditions = append(*conditions, newCondition)
		return true
	}

	changed := updateCondition(existingCondition, newCondition)

	return changed
}

func GetStatusCondition(conditions []gorchv1alpha1.Condition, conditionType gorchv1alpha1.ConditionType) *gorchv1alpha1.Condition {
	for i := range conditions {
		if conditions[i].Type == conditionType {
			return &conditions[i]
		}
	}
	return nil
}

func updateCondition(existingCondition *gorchv1alpha1.Condition, newCondition gorchv1alpha1.Condition) bool {
	changed := false
	if existingCondition.Status != newCondition.Status {
		changed = true
		existingCondition.Status = newCondition.Status
		existingCondition.LastTransitionTime = metav1.NewTime(time.Now())
	}
	if existingCondition.Reason != newCondition.Reason {
		changed = true
		existingCondition.Reason = newCondition.Reason

	}
	if existingCondition.Message != newCondition.Message {
		changed = true
		existingCondition.Message = newCondition.Message
	}
	return changed
}

func SetProgressingCondition(conditions *[]gorchv1alpha1.Condition, reason string, message string) {
	SetStatusCondition(conditions, gorchv1alpha1.Condition{
		Type:    ConditionProgessing,
		Status:  corev1.ConditionTrue,
		Reason:  reason,
		Message: message,
	})

}

func SetResourceCondition(conditions *[]gorchv1alpha1.Condition, component string, reason string, message string, status corev1.ConditionStatus) {
	condtype := component + "Ready"
	SetStatusCondition(conditions, gorchv1alpha1.Condition{
		Type:    gorchv1alpha1.ConditionType(condtype),
		Status:  status,
		Reason:  reason,
		Message: message,
	})
}

func SetCompleteCondition(conditions *[]gorchv1alpha1.Condition, status corev1.ConditionStatus, reason, message string) {
	SetStatusCondition(conditions, gorchv1alpha1.Condition{
		Type:    ConditionReconcileComplete,
		Status:  status,
		Reason:  reason,
		Message: message,
	})
}

=======
>>>>>>> f7cb3c7 (Second round of function standardization (#607))
func (r *GuardrailsOrchestratorReconciler) updateStatus(ctx context.Context, original *gorchv1alpha1.GuardrailsOrchestrator, update func(saved *gorchv1alpha1.GuardrailsOrchestrator)) (*gorchv1alpha1.GuardrailsOrchestrator, error) {
	saved := original.DeepCopy()

	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		err := r.Client.Get(ctx, client.ObjectKeyFromObject(original), saved)
		if err != nil {
			return err
		}
		update(saved)
		err = r.Client.Status().Update(ctx, saved)
		return err
	})
	return saved, err
}

func (r *GuardrailsOrchestratorReconciler) reconcileStatuses(ctx context.Context, orchestrator *gorchv1alpha1.GuardrailsOrchestrator) (ctrl.Result, error) {
	generatorReady, _ = r.checkGeneratorPresent(ctx, orchestrator.Namespace)
	deploymentReady, _ = utils.CheckDeploymentReady(ctx, r.Client, orchestrator.Name, orchestrator.Namespace)
	httpRouteReady, _ := utils.CheckRouteReady(ctx, r.Client, orchestrator.Name+"-http", orchestrator.Namespace)
	healthRouteReady, _ := utils.CheckRouteReady(ctx, r.Client, orchestrator.Name+"-health", orchestrator.Namespace)
	routeReady = httpRouteReady && healthRouteReady
	if generatorReady && deploymentReady && routeReady {
		_, updateErr := r.updateStatus(ctx, orchestrator, func(saved *gorchv1alpha1.GuardrailsOrchestrator) {
			utils.SetResourceCondition(&saved.Status.Conditions, "InferenceService", "InferenceServiceReady", "Inference service is ready", corev1.ConditionTrue)
			utils.SetResourceCondition(&saved.Status.Conditions, "Deployment", "DeploymentReady", "Deployment is ready", corev1.ConditionTrue)
			utils.SetResourceCondition(&saved.Status.Conditions, "Route", "RouteReady", "Route is ready", corev1.ConditionTrue)
			utils.SetCompleteCondition(&saved.Status.Conditions, corev1.ConditionTrue, utils.ReconcileCompleted, utils.ReconcileCompletedMessage)
			saved.Status.Phase = utils.PhaseReady
		})
		if updateErr != nil {
			utils.LogErrorUpdating(ctx, updateErr, "status", orchestrator.Name, orchestrator.Namespace)
			return ctrl.Result{}, updateErr
		}
	} else {
		_, updateErr := r.updateStatus(ctx, orchestrator, func(saved *gorchv1alpha1.GuardrailsOrchestrator) {
			if generatorReady {
				utils.SetResourceCondition(&saved.Status.Conditions, "InferenceService", "InferenceServiceReady", "Inference service is ready", corev1.ConditionTrue)
			} else {
				utils.SetResourceCondition(&saved.Status.Conditions, "InferenceService", "InferenceServiceNotReady", "Inference service is not ready", corev1.ConditionFalse)
			}
			if deploymentReady {
				utils.SetResourceCondition(&saved.Status.Conditions, "Deployment", "DeploymentReady", "Deployment is ready", corev1.ConditionTrue)
			} else {
				utils.SetResourceCondition(&saved.Status.Conditions, "Deployment", "DeploymentNotReady", "Deployment is not ready", corev1.ConditionFalse)
			}
			if routeReady {
				utils.SetResourceCondition(&saved.Status.Conditions, "Route", "RouteReady", "Route is ready", corev1.ConditionTrue)
			} else {
				utils.SetResourceCondition(&saved.Status.Conditions, "Route", "RouteNotReady", "Route is not ready", corev1.ConditionFalse)
			}

			utils.SetCompleteCondition(&saved.Status.Conditions, corev1.ConditionFalse, utils.ReconcileFailed, utils.ReconcileFailedMessage)
		})
		if updateErr != nil {
			utils.LogErrorUpdating(ctx, updateErr, "status", orchestrator.Name, orchestrator.Namespace)
			return ctrl.Result{}, updateErr
		}
	}
	return ctrl.Result{}, nil
}
