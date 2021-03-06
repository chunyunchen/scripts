#!/bin/bash

# author: Chunyun Chen
# date: 11/05/2015
# email: chunchen@redhat.com
# IRC: chunchen @ aos-qe
# desc: Testing scalability for logging and metrics parts

# the format for *time* command: %E=real time, %U=user time, %S=system time
export TIMEFORMAT="%E %U %S"

OS_MASTER="ec2-54-210-189-77.compute-1.amazonaws.com"
MASTER_CONFIG="/etc/origin/master/master-config.yaml"
SUBDOMAIN=""
OS_USER="xiazhao@redhat.com"
OS_PASSWD="redhat"
CURRENT_USER_TOKEN=""
MASTER_USER="root"
PROJECT="$(echo $OS_USER | grep -o -E '^[-a-z0-9]([-a-z0-9]*[a-z0-9])?')"
RESULT_DIR=~/test/data
METRICS_PERFORMANCE_FILE="metrics_performance.txt"
LOGGING_PERFORMANCE_FILE="logging_performance.txt"
pem_file=~/cfile/libra-new.pem
SSH="ssh -i $pem_file -o identitiesonly=yes $MASTER_USER@$OS_MASTER"
#SSHNODE="ssh -i $pem_file -o identitiesonly=yes $MASTER_USER@10.66.79.70"
ADMIN_CONFIG="admin.kubeconfig"
MASTER_CONFIG_FILE="master-config.yaml"
CONFIG_HOST="http://$OS_MASTER:8080/master"
ADMIN_CONFIG_URL="$CONFIG_HOST/$ADMIN_CONFIG"
MASTER_CONFIG_URL="$CONFIG_HOST/$MASTER_CONFIG_FILE"
CURLORSSH="ssh"
START_OPENSHIFT="false"
SUDO=""
########
podproject=${OS_USER}pj2
podimage="bmeng/hello-openshift"
initialPodNum=1
scaleNum=10
loopScaleNum=60

set -e
source ~/scripts/common.sh

function set_sudo {
    if [ "root" != "$MASTER_USER" ];
    then
        SUDO="sudo"
    fi
}

function get_nodes {
    oc get node |grep -v -e "SchedulingDisabled" -e "STATUS" |awk ' {print $1}'
}

function get_node_num {
    oc get node | grep -v -e "SchedulingDisabled" -e "STATUS" | wc -l
}

function get_subdomain {
    if [ "$CURLORSSH" == "ssh" ];
    then
        local subdomain_withspace="$($SSH "grep subdomain $MASTER_CONFIG | sed  's/subdomain.*\"\(.*\)\"/\1/'")"
    else
        local subdomain_withspace="$(grep subdomain $RESULT_DIR/$MASTER_CONFIG_FILE| sed  's/subdomain.*\"\(.*\)\"/\1/')"
    fi
    SUBDOMAIN=${subdomain_withspace##* }
    SUBDOMAIN=${SUBDOMAIN:-example.com}
}

# add admin permissions for user
function add_admin_permission {
    local role_name="${1:-cluster-admin}"
    local user_name="${2:-$OS_USER}"

    echo -e "${red_prefix}!! Added *$role_name* role to user *$user_name* !!${color_suffix}"
    if [ "$CURLORSSH" == "ssh" ];
    then
        $SSH "oadm policy add-cluster-role-to-user $role_name $user_name"
    else
        oadm policy add-cluster-role-to-user $role_name $user_name --config=$RESULT_DIR/$ADMIN_CONFIG
    fi
}

function remove_admin_permission {
    local role_name="${1:-cluster-admin}"
    local user_name="${2:-$OS_USER}"

    echo -e "${green_prefix}^_^ Removed *cluster-admin* role from user *$user_name* ^_^${color_suffix}"
    oadm policy remove-cluster-role-from-user $role_name $user_name
}

function create_isto_project {
    local project_name=${1:-openshift}
    local imagestream_file=${2:-https://raw.githubusercontent.com/openshift/origin/master/examples/image-streams/image-streams-rhel7.json}
    echo "Creating imagestream under openshift namespace..."
    $SSH "oc create -n $project_name -f $imagestream_file && oc create -n $project_name -f https://raw.githubusercontent.com/openshift/origin-metrics/master/metrics.yaml && oc create -n $project_name -f https://raw.githubusercontent.com/openshift/origin-aggregated-logging/master/deployment/deployer.yaml"
}

function create_default_pods {
    # --images='openshift/origin-${component}:latest
    $SSH "oc delete dc --all -n default; oc delete rc --all -n default; oc delete pods --all -n default; oc delete svc --all -n default; oc delete is --all -n openshift"
    # Add permission for creating router
    $SSH "oadm policy add-scc-to-user privileged system:serviceaccount:default:default"
    echo "Starting to create registry and router"
    $SSH "export CURL_CA_BUNDLE=/etc/origin/master/ca.crt; \
          chmod a+rwX /etc/origin/master/admin.kubeconfig; \
          chmod +r /etc/origin/master/openshift-registry.kubeconfig; \
          oadm registry --create --credentials=/etc/origin/master/openshift-registry.kubeconfig --config=/etc/origin/master/admin.kubeconfig; \
          oadm  router --credentials=/etc/origin/master/openshift-router.kubeconfig --config=/etc/origin/master/admin.kubeconfig --service-account=default"
}

function pull_metrics_and_logging_images_from_dockerhub {
    echo "Pulling down metrics and logging images form DockerHub registry..."
    #local image_prefix="openshift/origin-"
    local image_prefix="registry.access.redhat.com/openshift3/"
    local image_prefix2="rcm-img-docker01.build.eng.bos.redhat.com:5001/openshift3/"
    $SSH "docker pull ${image_prefix}metrics-hawkular-metrics;\
          docker pull ${image_prefix}metrics-heapster;\
          docker pull ${image_prefix}metrics-cassandra;\
          docker pull ${image_prefix}metrics-deployer;\
          docker pull ${image_prefix}logging-kibana;\
          docker pull ${image_prefix}logging-fluentd;\
          docker pull ${image_prefix}logging-elasticsearch;\
          docker pull ${image_prefix}logging-deployment;\
          docker pull ${image_prefix}logging-auth-proxy;\
          docker tag ${image_prefix}metrics-hawkular-metrics ${image_prefix2}metrics-hawkular-metrics;\
          docker tag ${image_prefix}metrics-heapster ${image_prefix2}metrics-heapster;\
          docker tag ${image_prefix}metrics-cassandra ${image_prefix2}metrics-cassandra;\
          docker tag ${image_prefix}metrics-deployer ${image_prefix2}metrics-deployer;\
          docker tag ${image_prefix}logging-kibana ${image_prefix2}logging-kibana;\
          docker tag ${image_prefix}logging-fluentd ${image_prefix2}logging-fluentd;\
          docker tag ${image_prefix}logging-elasticsearch ${image_prefix2}logging-elasticsearch;\
          docker tag ${image_prefix}logging-deployment ${image_prefix2}logging-deployment;\
          docker tag ${image_prefix}logging-auth-proxy ${image_prefix2}logging-auth-proxy;"
}

function start_origin_openshift {
    set_bash "sshos" "$SSH"

    local rs=`$SSH "openshift start --public-master=$OS_MASTER:8443 --write-config=/etc/origin"`
    echo $rs
    local node_config=$(echo "$rs" |grep -i "Created node config" |awk '{print $NF}')
    $SSH "sed -i -e '/loggingPublicURL:/d' -e '/metricsPublicURL:/d' $MASTER_CONFIG"
    # Delete existing OpenShift instance
    $SSH "ps aux |grep \"openshift start\" |grep -v grep; echo -n" > .openshift_process
    for pid in $(awk '{print $2}' .openshift_process)
    do
        $SSH "kill -9 $pid"
    done
    rm -f .openshift_process
    sleep 1

    echo "Starting Openshift Server"
    $SSH "echo export KUBECONFIG=/etc/origin/master/$ADMIN_CONFIG >> ~/.bashrc; nohup openshift start --node-config=$node_config/node-config.yaml --master-config=$MASTER_CONFIG &> openshift.log &"
    sleep 23
    # For automation cases related admin role
    $SSH "oc config use-context default/${OS_MASTER//./-}:8443/system:admin && mkdir -p /root/.kube && cp /etc/origin/master/admin.kubeconfig /root/.kube/config"


    local default_pod_num=$(get_resource_num "\(registry\|router\)" "pods" "default" "ssh")
    if [ 0 -eq $default_pod_num ];
    then
        create_default_pods
        create_isto_project
        pull_metrics_and_logging_images_from_dockerhub
        clone_gitrepo
    fi
}

function clone_gitrepo {
    echo "Cloning logging/metrics repos to $OS_MASTER under \$HOME dir for building related images..."
    $SSH "git clone https://github.com/openshift/origin-metrics.git; git clone https://github.com/openshift/origin-aggregated-logging.git"
}

Hawkular_metrics_appname="hawkular-metrics"
Kibana_ops_appname="kibana-ops"
Kibana_appname="kibana"
# Add public URL in /etc/origin/master/master-config.yaml for logging and metrics on master machine
function add_public_url {
    local restart_master="no"

    if [ "$CURLORSSH" == "ssh" ];
    then
        if [ -z "$($SSH "grep loggingPublicURL $MASTER_CONFIG")" ];
        then
            $SSH "sed -i -e '/publicURL:/a\  loggingPublicURL: https://$Kibana_ops_appname.$SUBDOMAIN' -e '/publicURL:/a\  loggingPublicURL: https://$Kibana_appname.$SUBDOMAIN' $MASTER_CONFIG"
            restart_master="yes"
        fi

        if [ -z "$($SSH "grep metricsPublicURL $MASTER_CONFIG")" ];
        then
            $SSH "sed -i '/publicURL:/a\  metricsPublicURL: https://$Hawkular_metrics_appname.$SUBDOMAIN/hawkular/metrics' $MASTER_CONFIG"
            restart_master="yes"
        fi

        if [ "$restart_master" == "yes" ];
        then
            if [ -z "$(echo $OS_MASTER |grep ec2)" ];
            then
                $SSH "systemctl restart  atomic-openshift-master.service"
                sleep 6
            else
                if [ "true" == "$START_OPENSHIFT" ];
                then
                    start_origin_openshift
                fi
            fi
        fi
    fi
}

# fix admin permissions for service account
function fix_oadm_permission {
    local role="$1"
    local user="$2"
    if [ "$CURLORSSH" == "ssh" ];
    then
        oadm policy add-cluster-role-to-user $role $user
    else
        oadm policy add-cluster-role-to-user $role $user --config=$RESULT_DIR/$ADMIN_CONFIG
    fi
}

# fix SCC permissions for service account
function fix_scc_permission {
    local scc="$1"
    local user="$2"
    oadm policy add-scc-to-user $scc $user
}

# fix general permissions for service account
function fix_oc_permission {
    local role="$1"
    local user="$2"
    oc policy add-role-to-user $role $user
}

function get_resource_num {
    local regexp="$1"
    local resource="$2"
    local project_name="${3:-$PROJECT}"
    if [ -z "$4" ];
    then
        oc get $resource -n $project_name | sed -n "/$regexp/p" |wc -l
    else
        $SSH "oc get $resource -n $project_name | sed -n \"/$regexp/p\" |wc -l"
    fi
}

function delete_oauthclient {
    # For logging part
    resource_num=$(get_resource_num "kibana-proxy" "oauthclients")
    if [ "$resource_num" == "1" ];
    then
        oc delete oauthclients "kibana-proxy"
    fi
}

function delete_project {
    local projects="$@"
    for project_name in $projects
    do
        if [ "openshift-infra" == "$project_name" ];
        then
            echo -e "\033[31;49;1mOops!!! The *openshift-infra* is a default project, it's very import for OpenShift service! we can NOT delete it!\033[39;49;0m\n"
            exit 1
        fi
        if [ "1" == "$(get_resource_num "$project_name" "projects")" ];
        then
          oc delete project $project_name
          check_resource_validation "deleting project *$project_name*" "$project_name" "0" "projects"
        fi
    done
}

function create_project {
    local project_name="$PROJECT"
    if [ "0" == "$(get_resource_num "$project_name" "projects")" ];
    then
      oc new-project $project_name
      check_resource_validation "creating PROJECT *$project_name*" "$project_name" "1" "projects"
    fi
    oc project $project_name
}

# Log into OpenShift server and create PROJECT/namespace for user
function login_openshift {
    local del_proj="$1"
    get_subdomain
    oc login $OS_MASTER -u $OS_USER -p $OS_PASSWD
    if [ "$CURLORSSH" != "ssh" ];
    then
        curl $ADMIN_CONFIG_URL -o $RESULT_DIR/$ADMIN_CONFIG 2>&-
        curl $MASTER_CONFIG_URL -o $RESULT_DIR/$MASTER_CONFIG_FILE 2>&-
    fi

    CURRENT_USER_TOKEN=$(get_token_for_current_user)

    if [ "--del-proj" == "$del_proj" ];
    then
        delete_project $podproject $PROJECT
    fi
    create_project
}

# check specific pods number,eg: Running pod
function check_resource_validation {
    local msg_notification="$1"
    local regexp="$2"
    local resource_num="${3:-3}"
    local resource="${4:-pods}"
    echo -e "${blue_prefix}Wait $msg_notification...${color_suffix}"
    while [ "$(get_resource_num "$regexp" "$resource")" != "$resource_num" ]
    do
        sleep 6
    done
    echo -e "${green_prefix}Success for $msg_notification!${color_suffix}"
}

# get the names of specific status pods, will get all pods in all PROJECTs on master by default
function get_resource_in_all_projects {
    local resource="$1"
    local regexp="$2"
    oc get $resource --all-namespaces | sed -n "/$regexp/p" | awk '{print $1,$2}'
}

function get_resource_in_a_project {
    local resource="$1"
    local project_name="$2"
    local regexp="$3"
    oc get $resource -n $project_name| sed -n "/$regexp/p" | awk '{print $1}'
}

HCH_stack="https://raw.githubusercontent.com/openshift/origin-metrics/master/metrics.yaml"
#Image_prefix="openshift/origin-"
Image_prefix="rcm-img-docker01.build.eng.bos.redhat.com:5001/openshift3/"
#Image_prefix="brew-pulp-docker01.web.qa.ext.phx1.redhat.com:8888/openshift3/"
#Image_prefix="registry.access.redhat.com/openshift3/"
Image_version="latest"
Use_pv=false

function set_annotation {
    local is_name="$1"
    local annotation_name="${2:-openshift.io/image.insecureRepository}"
    local annotation_value="${3:-true}"
    oc patch imagestreams $is_name  -p ''{\"metadata\":{\"annotations\":{\"$annotation_name\":\"$annotation_value\"}}}''
    oc tag --source=docker ${Image_prefix}${is_name} ${is_name}:${Image_version}
    oc import-image $is_name
}

# hch = hawkular, cassanda & heapster, they are Mertrics part
function up_hch_stack {
    # Create the Deployer Service Account
    oc create -f $SA_metrics_deployer
    # fix permissions for service account
    fix_oadm_permission cluster-reader system:serviceaccount:$PROJECT:heapster
    fix_oc_permission edit system:serviceaccount:$PROJECT:metrics-deployer
    # Create the Hawkular Deployer Secret
    oc secrets new metrics-deployer nothing=/dev/null
    # Deploy hch stack
    oc process openshift//metrics-deployer-template -v HAWKULAR_METRICS_HOSTNAME=$Hawkular_metrics_appname.$SUBDOMAIN,IMAGE_PREFIX=$Image_prefix,IMAGE_VERSION=$Image_version,USE_PERSISTENT_STORAGE=$Use_pv,MASTER_URL=https://$OS_MASTER:8443 \
    |oc create -f -
    check_resource_validation "starting Metrics stack" "\(heapster\|hawkular\).\+1\/1\s\+Running"
}

ES_ram="1024M"
ES_cluster_size="1"
EFK_deployer="https://raw.githubusercontent.com/openshift/origin-aggregated-logging/master/deployment/deployer.yaml"
# should be "true" or "false" value
TORF=false

# efk = elasticsearch, fluentd & kibana, they are Logging part
function up_efk_stack {
    # Create the Deployer Secret
    oc secrets new logging-deployer nothing=/dev/null
    # Create the Deployer ServiceAccount
    oc create -f - <<API
apiVersion: v1
kind: ServiceAccount
metadata:
    name: logging-deployer
secrets:
- name: logging-deployer
API
    delete_oauthclient
    # fix permissions for service account
    fix_oc_permission edit system:serviceaccount:$PROJECT:logging-deployer
    fix_oadm_permission cluster-reader system:serviceaccount:$PROJECT:aggregated-logging-fluentd
    # Deploy efk stack
    local kibana_ops_hostname=""
    if [ "true" == "$TORF" ];
    then
        kibana_ops_hostname="KIBANA_OPS_HOSTNAME=$Kibana_ops_appname.$SUBDOMAIN"
    fi
    echo "oc process openshift//logging-deployer-template -v ENABLE_OPS_CLUSTER=$TORF,IMAGE_PREFIX=$Image_prefix,KIBANA_HOSTNAME=$Kibana_appname.$SUBDOMAIN,$kibana_ops_hostname,PUBLIC_MASTER_URL=https://$OS_MASTER:8443,ES_INSTANCE_RAM=$ES_ram,ES_CLUSTER_SIZE=$ES_cluster_size,IMAGE_VERSION=$Image_version,MASTER_URL=https://$OS_MASTER:8443 |oc create -f -"
    oc process openshift//logging-deployer-template -v ENABLE_OPS_CLUSTER=$TORF,IMAGE_PREFIX=$Image_prefix,KIBANA_HOSTNAME=$Kibana_appname.$SUBDOMAIN,$kibana_ops_hostname,PUBLIC_MASTER_URL=https://$OS_MASTER:8443,ES_INSTANCE_RAM=$ES_ram,ES_CLUSTER_SIZE=$ES_cluster_size,IMAGE_VERSION=$Image_version,MASTER_URL=https://$OS_MASTER:8443 |oc create -f -
    check_resource_validation "completing EFK deployer" "\logging-deployer.\+0\/1\s\+Completed" "1"
    # Create the supporting definitions
    oc process logging-support-template | oc create -f -
    # Set annotation for each logging images
    for is in $(get_resource_in_a_project "imagestreams" "$PROJECT" "logging")
    do
        set_annotation $is
    done
    check_resource_validation "creating dc/logging-fluentd" "logging-fluentd" "1" "deploymentconfigs"
    check_resource_validation "creating rc/logging-fluentd-1" "logging-fluentd-1" "1" "replicationcontrollers"
    # Enable fluentd service account
    fix_scc_permission "hostmount-anyuid" "system:serviceaccount:$PROJECT:aggregated-logging-fluentd"
    # Scale Fluentd Pod
    local fluentd_pod_num=$(get_node_num)
    local additional_num=2
    if [ "true" == "$TORF" ];
    then
        additional_num=4
    fi
    oc scale dc/logging-fluentd --replicas=$fluentd_pod_num
    oc scale rc/logging-fluentd-1 --replicas=$fluentd_pod_num
    check_resource_validation "starting EFK stack" "\(logging-es\|logging-fluentd\|logging-kibana\).\+\+Running" "$(($additional_num + $fluentd_pod_num))"
}

# Must have *cluster-admin* permission for log in user
function get_token_for_user {
    local user="$1"
    token=$(oc get oauthaccesstokens |grep $user |sort -k5 | tail -1 | awk '{print $1}')
    return $token
}

function get_token_for_current_user {
    oc whoami -t
}

function get_container_name_in_pod {
    local pod_name=$1
    local project_name=${2:-$PROJECT}
    echo "7777"
    echo "oc describe pods $pod_name -n $project_name "
    oc describe pods $pod_name -n $project_name |sed -n '/Container ID/{g;1!p;};h' | sed 's/\( \|:\)//g'
}

function check_metrics_or_logs {
    local catalog=$1
    local project_name=${2:-$PROJECT}
    local pod_name=$3
    local pod_num=$(get_resource_num "\(Running\|Completed\)" "pods --all-namespaces")
    echo "6666"
    if [ "$catalog" == "efk" ];
    then
        for container_name in $(get_container_name_in_pod $pod_name $project_name):
        do
            (time curl -k -H "Authorization: Bearer $CURRENT_USER_TOKEN" https://$Kibana_appname.$SUBDOMAIN/#/discover?_a=\(columns:\!\(kubernetes_container_name,$container_name\),index:"$project_name.*",interval:auto,query:\(query_string:\(analyze_wildcard:\!t,query:"kubernetes_pod_name:%20${pod_name}%20%26%26%20kubernetes_namespace_name:%20$project_name"\)\),sort:\!\(time,desc\)\)\&_g=\(time:\(from:now-1w,mode:relative,to:now\)\)) 2> .ctime
        local curl_real_time=$(tail -1 .ctime | awk '{print $1}')
        echo "$curl_real_time" >> .allmetrics
        done
    else
        time (curl --insecure -H "Authorization: Bearer $CURRENT_USER_TOKEN" -H "Hawkular-tenant: $project_name" -X GET https://$Hawkular_metrics_appname.$SUBDOMAIN/hawkular/metrics/metrics?tags={"pod_name":"$pod_name"} 2>&- > .metric$RANDOM) 2> .ctime
        #$SSHNODE "time curl --insecure -H \"Authorization: Bearer $CURRENT_USER_TOKEN\" -H \"Hawkular-tenant: $project_name\" -X GET https://172.30.9.139:443/hawkular/metrics/metrics?tags={\"pod_name\":\"$pod_name\"}"</dev/null 2>&- > .metric 2> .ctime
        local curl_real_time=$(tail -1 .ctime | awk '{print $1}')
        echo "$pod_name $pod_num $curl_real_time" >> .allmetrics
    fi
}

function inspect_pods {
    local catalog=${1:-hch}
    local project_name=${2:-allprojects}
    local pod_name=$3
    echo "Wait to access Metrics/Logging for Pods..."
    cat /dev/null > .allmetrics
    if [ "$project_name" == "allprojects" ];
    then
        echo "111"
        get_resource_in_all_projects "pods" "\(Running\|Completed\)" > allpods.txt
        while read LINE
        do
            local prj=$(echo "$LINE" | awk '{print $1}')
            local pod=$(echo "$LINE" | awk '{print $2}')
            check_metrics_or_logs $catalog $prj $pod
        done < allpods.txt
        rm -f ./allpods.txt
    elif [ -z "$pod_name" ];
    then
        pods=$(get_resource_in_a_project "pods" "$project_name" "\(Running\|Completed\)")
        for pod in $pods
        do
            check_metrics_or_logs $catalog $project_name $pod
        done
    else
        check_metrics_or_logs $catalog $project_name $pod_name
    fi
    if [ "hch" == "$catalog" ];
    then
        local pod_num=$(head -1 .allmetrics | awk '{print $1}')
        local min_time=$(awk 'BEGIN {min = 1999999} {if ($2<min) min=$2 fi} END {print  min*1000}' .allmetrics)
        local max_time=$(awk 'BEGIN {max = 0} {if ($2>max) max=$2 fi} END {print max*1000}' .allmetrics)
        local avg_time=$(awk '{sum+=$2} END {print (sum/NR)*1000}' .allmetrics)
        echo "$pod_num,$min_time,$avg_time,$max_time" >> $RESULT_DIR/$METRICS_PERFORMANCE_FILE && rm -f .ctime .metric .allmetrics
    else
        local container_num=$(cat .allmetrics | wc -l)
        local min_time=$(awk 'BEGIN {min = 1999999} {if ($1<min) min=$1 fi} END {print  min*1000}' .allmetrics)
        local max_time=$(awk 'BEGIN {max = 0} {if ($1>max) max=$1 fi} END {print max*1000}' .allmetrics)
        local avg_time=$(awk '{sum+=$1} END {print (sum/NR)*1000}' .allmetrics)
        echo "$container_num,$min_time,$avg_time,$max_time" >> $RESULT_DIR/$LOGGING_PERFORMANCE_FILE && rm -f .ctime .metric .allmetrics
    fi
    echo "Finished to access Metrics/Logging!"
}

function lm_performance {
  create_project $podproject
  local rc_name="testrc"
  echo "{\"apiVersion\":\"v1\",\"kind\":\"ReplicationController\",\"metadata\":{\"name\":\"$rc_name\"},\"spec\":{\"replicas\":$initialPodNum,\"template\":{\"metadata\":{\"labels\":{\"name\":\"test-pods\"}},\"spec\":{\"containers\":[{\"image\":\"$podimage\",\"name\":\"test-pod\"}]}}}}" | oc create -f -
  check_resource_validation "creating POD *$rc_name*" "$rc_name.\+\s\+Running" "$initialPodNum"
  local inum=1
  while [ $inum -le $loopScaleNum ]
  do
    inspect_pods "efk"
    inspect_pods "hch"
    local pod_num=$(expr $initialPodNum + $inum \* $scaleNum)
    scale -p $podproject -o $rc_name -n $pod_num
    check_resource_validation "creating PODs($pod_num) *$rc_name*" "$rc_name.\+\s\+Running" "$pod_num"
    inum=$(expr $inum + 1)
  done
}

function start_hch_and_efk {
    # If '$1' is --del-proj, then will delete the PROJECT named "$PROJECT" and re-create
    login_openshift "$1"
    up_hch_stack
    up_efk_stack
}

function show_me {
  echo "$1"
}

function grant_permission {
    show_me "Add permission for service account"
    fix_oc_permission edit system:serviceaccount:$PROJECT:logging-deployer && show_me "grant edit for system:serviceaccount:$PROJECT:logging-deployer"
    fix_oadm_permission cluster-reader system:serviceaccount:$PROJECT:aggregated-logging-fluentd && show_me "grant cluster-reader to system:serviceaccount:$PROJECT:aggregated-logging-fluentd"
    fix_oadm_permission cluster-reader system:serviceaccount:$PROJECT:heapster && show_me "grant cluster-reader to system:serviceaccount:$PROJECT:heapster"
    fix_oc_permission edit system:serviceaccount:$PROJECT:metrics-deployer && show_me "grant edit to system:serviceaccount:$PROJECT:metrics-deployer"
    fix_scc_permission "privileged" "system:serviceaccount:$PROJECT:aggregated-logging-fluentd" && show_me "grant scc privliged to system:serviceaccount:$PROJECT:aggregated-logging-fluentd"
}

function scale {
    local obj_name=""
    local resource_name="rc"
    local incremental_num=1
    local project_name="$PROJECT"
    local pod_num=""

    OPTIND=1
    while getopts ":dsr:i:n:p:o:m:" opt
    do
        case $opt in
            r) resource_name="$OPTARG" ;;
            i) incremental_num=$OPTARG ;;
            n) pod_num=$OPTARG ;;
            p) project_name="$OPTARG" ;;
            o) obj_name="$OPTARG" ;;
        esac
    done
    if [ -z "$pod_num" ];
    then
        current_pod_num=$(oc get pods -n $project_name |grep $obj_name |wc -l)
        pod_num=$(($current_pod_num+$incremental_num))
    fi
    echo "Scale $resource_name $obj_name to $pod_num"
    oc scale $resource_name $obj_name --replicas=$pod_num -n $project_name
}

function usage {
    echo "=============================================================================================================="
    echo "=============================================================================================================="
    echo "Usage:"
    echo "      $(basename $0) [-d] hch|efk|startall"
    echo "              -d: Delete current project, then re-create it"
    echo "      $(basename $0) chk|pfm|pms"
    echo "      $(basename $0) -o OBJ_NAME [-i INCREMENTAL_NUM |-n TOTAL_POD_NUM |-r RESOURCE_NAME(dc/rc) |-p PROJECT] scale"
    echo "=============================================================================================================="
    echo "=============================================================================================================="
    echo "scale: Scale up/down pods via replication controller or deployment config"
    echo "hch: Start Metrics stack application for Heapster,Cassada & Hawkular components"
    echo "efk: Start Logging stack application for Elasticsearch,Fluentd & Kibana components"
    echo "chk: Check logs and metrics for Logging and Metrics Pods"
    echo "startall: Start Logging stack and Metrics stack applications"
    echo "pfm: Execute logging and metrics performance testing"
    echo "pms: Add properly permission to service accout, mostly used for debugging"
}

# Show json to create under openshift project for tsting JVM console related
function show_is_fis_java_openshift {
    is_fis=/home/chunchen/test/cfile/is_fis-java-openshift.json
    echo "From File: $is_fis"
    echo "Available Image Prefix: rcm-img-docker01.build.eng.bos.redhat.com:5001 | registry.access.redhat.com "
    cat $is_fis
    xclip -sel clipboard /home/chunchen/test/cfile/is_fis-java-openshift.json
    xclip /home/chunchen/test/cfile/is_fis-java-openshift.json
    echo -e "${green_prefix}The file content have been pasted to clipboard, paste via Ctrl+V or Insert+Shift${color_suffix}"
}

function build_camel_docker_image {
    source ~/scripts/common.sh
    jdk8_path=`$SSH "$SUDO rpm -qa|grep openjdk |grep 1.8|head -1"`
    $SSH "$SUDO yum install -y maven java-1.8.0-openjdk-devel.x86_64 &&\
          rm -f /etc/alternatives/java_sdk &&\
          ln -s /usr/lib/jvm/$jdk8_path /etc/alternatives/java_sdk &&\"
          git clone https://github.com/fabric8io/ipaas-quickstarts.git"

    for img_type in java/mainclass java/camel-spring karaf/camel-amq/
    do
    $SSH  "cd ipaas-quickstarts/quickstart/$img_type &&\
          mvn clean install docker:build"
    done
    $SSH "docker tag -f fabric8/karaf-camel-amq:2.3-SNAPSHOT chunyunchen/karaf-camel-amq:2.3-SNAPSHOT"
    $SSH "docker tag -f fabric8/java-mainclass:2.3-SNAPSHOT chunyunchen/java-mainclass:2.3-SNAPSHOT"
    $SSH "docker tag -f fabric8/camel-spring:2.3-SNAPSHOT chunyunchen/camel-spring:2.3-SNAPSHOT"
    $SSH "docker push chunyunchen/camel-spring:2.3-SNAPSHOT"
    $SSH "docker push chunyunchen/java-mainclass:2.3-SNAPSHOT"
    $SSH "docker push chunyunchen/karaf-camel-amq:2.3-SNAPSHOT"
    echo "oc new-app --docker-image=[chunyunchen/karaf-camel-amq:2.3-SNAPSHOT | chunyunchen/java-mainclass:2.3-SNAPSHOT | chunyunchen/camel-spring:2.3-SNAPSHOT] ##To create app"
    echo "${red_prefix}Note:$color_suffix Need add *${green_prefix}name: jolokia${color_suffix}* to DC(yaml format) under ${green_prefix}spec.containers.ports${color_suffix}"
}

# For testing JVM console related
function create_camel_apps {
    camel_template=/home/chunchen/test/cfile/camel-quickstart-template.json

    echo "From file: $camel_template"
    echo "Create camel apps..."
    oc new-app --file=$camel_template --param=GIT_REPO=https://github.com/fabric8io/ipaas-quickstarts.git,GIT_REF=redhat,GIT_CONTEXT_DIR=quickstart/cdi/camel
}

function chain_build {
    # For testing chain-build functional feature
    local root_dir=/home/chunchen/test/cfile
    local sti_json=chainbuild-sti.json
    local docker_json=chainbuild-docker.json
    PROJECT=$PROJECT-chain

    delete_project $PROJECT
    #check_resource_validation "deleting project *$PROJECT*" "$PROJECT" "0" "projects"
    create_project $PROJECT
    echo -e "${blue_prefix}Start creating resources...${color_suffix}"
    local root_dir=/home/chunchen/test/cfile
    oc new-app --file=$root_dir/$sti_json && oc new-app --file=$root_dir/$docker_json
    check_resource_validation "first s2i build to completed" "frontend-sti-1.\+Running" "2"
    oc start-build python-sample-build-sti
    check_resource_validation "second s2i build to completed" "python-sample-build-sti.\+Completed" "2"
    echo -e "${blue_prefix}ImamgeStream updated:${color_suffix}"
    oc get is | grep sample-sti
    echo -e "${blue_prefix}Builds:${color_suffix}"
    oc get build
}

function push_docker {
#    oc process -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/build/ruby20rhel7-template-sti.json | oc create -f -
    oc delete project chun
    sleep 6
    oc new-project chun
    oc secrets new-dockercfg pushme --docker-username=chunyunchen --docker-password=redhat7 --docker-email=chunchen@redhat.com
    oc secrets add serviceaccount/builder secrets/pushme
    echo -e "oc process -f ~/test/cfile/stibuild_push_secret.json | oc create -f - \
          \nOR\n \
oc process -f ~/test/cfile/dockerbuild_push_secret.json | oc create -f -"
    #echo "Add below to origin-ruby-sample imagestream section"
#    cat << EOF
#         "spec":{
#         "dockerImageRepository": "docker.io/chunyunchen/origin-ruby-sample"
#       },
#EOF
#    sleep 6
#    oc edit imagestream/origin-ruby-sample -o json
#    echo "Add below to output: section"
#    cat << EOF
#output:
#    pushSecret:
#      name: pushme
#EOF
#    sleep 6
    echo "oc edit bc/ruby-sample-build "
    echo "eg: oc start-build ruby-sample-build"
}

function main {

    set_sudo
    # If '-d' is specified, then will delete the PROJECT named "$PROJECT" and re-create
    local fun_obj="${!#}"
    local del_project=''
	while getopts ":dskr:i:n:p:o:m:" opt; do
        case $opt in
            d) del_project='--del-proj'
               ;;
            k) TORF='true'
               ;;
            p) PROJECT="$OPTARG"
               ;;
            s) START_OPENSHIFT="true"
               ;;
            m) OS_MASTER="$OPTARG"
               SSH="ssh -i $pem_file -o identitiesonly=yes $MASTER_USER@$OS_MASTER"
               ;;
        esac
    done

    case $fun_obj in
        "os")
            start_origin_openshift
            ;;
        "hch")
            login_openshift "$del_project"
            add_public_url
            up_hch_stack
            ;;
        "efk")
            login_openshift "$del_project"
            add_public_url
            add_admin_permission
            up_efk_stack
            remove_admin_permission
            ;;
        "chk")
            login_openshift
            inspect_pods
            ;;
        "pfm")
            login_openshift
            lm_performance
            ;;
        "pms")
            login_openshift
            grant_permission
            ;;
        "scale")
            scale $*
            ;;
        "startall")
            add_public_url
            add_admin_permission
            start_hch_and_efk "$del_project"
            remove_admin_permission
            ;;
        "camel")
            create_camel_apps
            ;;
        "show-is")
            show_is_fis_java_openshift
            ;;
        "build_camel")
            build_camel_docker_image
            ;;
        "chainbuild")
            login_openshift "$del_project"
            chain_build
            ;;
        "push")
            #login_openshift "$del_project"
            push_docker
            ;;
        "docker")
            echo -e "sed -i '/OPTIONS/a OPTIONS=\"--confirm-def-push=false\"' /etc/sysconfig/docker\nservice docker restart"
            ;;
        "ctrl")
            admission_controller
            ;;
        *) usage
            ;;
    esac
}

function admission_controller {
echo -n "kubernetesMasterConfig:
  admissionConfig:
    pluginOrderOverride:
    - NamespaceLifecycle
    - OriginPodNodeEnvironment
    - LimitRanger
    - ServiceAccount
    - SecurityContextConstraint
    - ResourceQuota
    - SCCExecRestrictions
    - InitialResources
    pluginConfig:
      InitialResources:
        configuration:
          apiVersion: v1
          kind: InitialResourcesConfig

oc new-app --docker-image=fabric8/apiman:2.2.94
oc new-app --docker-image=fabric8/apiman-gateway:2.2.94
oc new-app --docker-image=fabric8/elasticsearch-k8s:2.2.1
"
}

main $*
