#!/bin/env python2

from __future__ import print_function

import os, sys, re, time
import signal
import pipes
from subprocess import check_call,check_output,CalledProcessError,STDOUT
from ConfigParser import SafeConfigParser
from argparse import ArgumentParser, Namespace
from datetime import datetime

try:
    from termcolor import cprint
except ImportError:
    print('No termcolor module found,please download "termcolor.py" file from same place!')
    yes = raw_input('Download "termcolor.py" under current dir? [y/n]: ')
    if 'y' == yes.lower():
        dstFile = raw_input('input the URL of file(eg: http://10.66.128.58/client/termcolor.py): ')
        check_output('wget {}'.format(dstFile), shell=True)
        print('\033[1;31m[IMPORTANT] Please copy it to the same directory as "easy-aos.py"!!! [IMPORTANT]\033[0m')
        os.sys.exit(1)
    else:
       print("Note: The default color will be used for output messages.")
       cprint = print

config = SafeConfigParser()

def signal_handler(signal, frame):
    cprint('\nStopped by Ctrl+C!','red')
    sys.exit(1)

class AOS(object):
    '''Make easier for OpenShift tests!'''

    osConfigFile = "./aos.conf"
    osUser=""
    osPasswd=""
    masterUser=""
    master=""
    masterConfigRoot=""
    masterConfigFile=""
    kubeConfigFile=""
    pemFile=""
    hawkularMetricsAppname=""
    kibanaOpsAppname=""
    kibanaAppname=""
    SAMetricsDeployer=""
    HCHStack=""
    imagePrefix=""
    imageVersion=""
    enablePV=""
    ESRam=""
    ESClusterSize=1
    ESPVCSize = 10
    EFKDeployer=""
    RegistryQEToken = ""

    SSHIntoMaster=""
    ScpFileFromMaster=""
    osProject=""
    delProject = False
    pullLoggingMetricsImage = False

    @staticmethod
    def generate_default_config():
        '''Create the default config file if not exists'''

        config.add_section("master")
        config.add_section("project")
        config.add_section("image")
        config.add_section("ssh")
        config.set('project','os_user','')
        config.set('project','os_passwd','redhat')
        config.set('project','master_user','root')
        config.set('master','master','')
        config.set('master','master_config_root','/etc/origin/master')
        config.set('master','master_config_file','master-config.yaml')
        config.set('master','kube_config_file','admin.kubeconfig')
        config.set('ssh','pem_file','')
        config.set('image','hawkular_metrics_appname','hawkular-metrics')
        config.set('image','kibana_ops_appname','kibana-ops')
        config.set('image','kibana_appname','kibana')
        config.set('image','serviceaccount_metrics_deployer','https://raw.githubusercontent.com/openshift/origin-metrics/master/metrics-deployer-setup.yaml')
        config.set('image','hch_stack','https://raw.githubusercontent.com/openshift/origin-metrics/master/metrics.yaml')
        config.set('image','image_prefix','brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888/openshift3/')
        config.set('image','image_version','latest')
        config.set('image','enable_pv','false')
        config.set('image','elastic_ram','1024M')
        config.set('image','elastic_cluster_size','1')
        config.set('image', 'elstic_pvc_size', '10')
        config.get('image', 'registryqe_token')
        config.set('image','efk_deployer','https://raw.githubusercontent.com/openshift/origin-aggregated-logging/master/deployment/deployer.yaml')

        with open(AOS.osConfigFile, 'wb') as defaultconfig:
           config.write(defaultconfig)

    @staticmethod
    def show_current_config():
        config.read(AOS.osConfigFile)
        for section in config.sections():
            items = config.items(section)
            items_with_newline = '\n'.join([' = '.join(item) for item in items])
            cprint('\n['+section+']', 'green')
            cprint(items_with_newline, 'blue')

    @staticmethod
    def get_config(args):
        config.read(AOS.osConfigFile)
        AOS.osUser = config.get("project","os_user")
        AOS.osPasswd = config.get("project","os_passwd")
        AOS.masterUser = config.get("project","master_user")
        AOS.master = config.get("master","master")
        AOS.masterConfigRoot = config.get("master","master_config_root")
        AOS.masterConfigFile = config.get("master","master_config_file")
        AOS.kubeConfigFile = config.get("master","kube_config_file")
        AOS.pemFile = config.get("ssh","pem_file")
        AOS.hawkularMetricsAppname = config.get("image","hawkular_metrics_appname")
        AOS.kibanaOpsAppname = config.get("image","kibana_ops_appname")
        AOS.kibanaAppname = config.get("image","kibana_appname")
        AOS.SAMetricsDeployer = config.get("image","serviceaccount_metrics_deployer")
        AOS.HCHStack = config.get("image","hch_stack")
        AOS.imagePrefix = config.get("image","image_prefix")
        AOS.imageVersion = config.get("image","image_version")
        AOS.enablePV = config.get("image","enable_pv")
        AOS.ESRam = config.get("image","elastic_ram")
        AOS.RegistryQEToken = config.get("image","registryqe_token")
        AOS.ESClusterSize = config.get("image","elastic_cluster_size")
        AOS.ESPVCSize = config.get("image","elastic_pvc_size")
        AOS.EFKDeployer = config.get("image","efk_deployer")

        if AOS.osUser:
           AOS.osProject = re.match(r'\w+',AOS.osUser).group(0)
        
        arg_map_to_param = {'m': 'master',
                            'p': 'osProject',
                            'd': 'delProject',
                            'pull': 'pullLoggingMetricsImage',
                            'prefix': 'imagePrefix',
                            'mtag': 'imageVersion'
                           }
        existedArgs = vars(args).items()
        for arg,value in existedArgs:
            aosVar = arg_map_to_param.get(arg)
            if value and aosVar: 
               setattr(AOS, aosVar, value)

    @staticmethod
    def echo_user_info():
        cprint("User info:",'blue')
        print("master: {}".format(AOS.master))
        print("user: {}".format(AOS.osUser))
        print("project: {}".format(AOS.osProject))
        print("image prefix: {}".format(AOS.imagePrefix))
        print("image version: {}".format(AOS.imageVersion))
     
    @staticmethod
    def get_current_time_str():
        now = datetime.now()
        return now.strftime("%Y-%m-%d %H:%M:%S")

    @staticmethod
    def echo_command(cmd="Please wait..."):
        cprint("[{}]Running Command: {}\n".format(AOS.get_current_time_str(), cmd),'magenta')

    @staticmethod
    def echo(msg):
        prefix_str = '>' * len('Running Command')
        print("[{}]: {}".format(prefix_str, msg))

    @staticmethod
    def ssh_validation():
        try:
            command = "date > /dev/null"
            remote_command = '%s {}'.format(pipes.quote(command)) % AOS.SSHIntoMaster
            returncode = check_call(remote_command, shell=True,)
            return returncode
        except Exception, errMsg:
            os.sys.exit()

    @classmethod
    def check_validation(cls,args):
        cprint("Checking confiures...",'blue')
        if not os.path.isfile(AOS.osConfigFile):
            AOS.generate_default_config()

        AOS.get_config(args)

        notification_items = []
        if not AOS.master:
            notification_items.append("[master].master")
        if not AOS.osUser:
            notification_items.append("[project].os_user")
        if not AOS.pemFile:
            notification_items.append("[ssh].pem_file")

        if 0 < len(notification_items):
            cprint("Please set below parameter(s) under %s config file:" % os.path.abspath(AOS.osConfigFile),'green',on_color='on_blue',attrs=['bold'])
            cprint('\n'.join(notification_items),'green')
            os.sys.exit()

        AOS.SSHIntoMaster = "ssh -i %s -o identitiesonly=yes -o ConnectTimeout=10 %s@%s" % (os.path.expanduser(AOS.pemFile), AOS.masterUser, AOS.master)
        AOS.ScpFileFromMaster = "scp -i %s -o identitiesonly=yes -o ConnectTimeout=10 %s@%s:" % (os.path.expanduser(AOS.pemFile), AOS.masterUser, AOS.master)
        AOS.ssh_validation()
        AOS.echo_user_info()

    @staticmethod
    def run_ssh_command(cmd, asShell=True,ssh=True):
        remote_command = cmd

        if ssh:
            remote_command = '%s {}'.format(pipes.quote(cmd)) % AOS.SSHIntoMaster

        AOS.echo_command(remote_command)

        try:
            outputs = check_output(remote_command, shell=asShell, stderr=STDOUT)
            return outputs
        except (CalledProcessError,OSError), e:
            if e.output and "no process found" not in e.output and "not found" not in e.output:
                AOS.echo_command(remote_command)
                cprint(e.output,'red')
                cprint("Aborted!!!",'red',attrs=['bold'])
                os.sys.exit()
            elif "command" in e.output:
                scpFileCMD = AOS.ScpFileFromMaster+"/etc/origin/master/admin.kubeconfig ."
                check_output(scpFileCMD, shell=asShell, stderr=STDOUT)
                localCMD = '{} --config={}'.format(cmd, 'admin.kubeconfig')
                outputs = check_output(localCMD, shell=asShell, stderr=STDOUT)
                return outputs

    @classmethod
    def do_permission(cls,role_type,role_name,user=None):

        if not user:
            user = AOS.osUser
        enableSSH = False
        pre_cmd = "oc policy"
        if re.match(r".*(cluster|scc-).*",role_type):
            enableSSH = True
            pre_cmd = "oadm policy"
        if "add-" in role_type:
            if "cluster" in role_type:
                cprint("Note: *%s* user has '%s' admin role! Be Careful!!!" % (user,role_name),'red')
            else:
                cprint("Added '%s' role to *%s* user!" % (role_name,user),'blue')
        elif "remove-" in role_type:
            cprint("Removed '%s' role from *%s* user." % (role_name,user),'green')
        command = "%s %s %s %s" % (pre_cmd,role_type,role_name,user)
        AOS.run_ssh_command(command,ssh=enableSSH)

    @staticmethod
    def resource_validate(cmd, reStr, dstNum=3, enableSsh=False):
        cprint("Wait above operation to finished...",'blue')

        iloop = 50
        interval = 6
        timeout = iloop * interval
        output = ""
        while dstNum != len(re.findall(reStr,output)) and 0 < iloop:
            time.sleep(interval)
            iloop -= 1
            output = AOS.run_ssh_command(cmd,ssh=enableSsh)
            cprint(output)

        if iloop == 0:
            cprint("Operation is not finished, timeout {} seconds".format(timeout),'yellow')
            os.sys.exit()

    @classmethod
    def add_project(cls):
        if AOS.delProject:
            cprint("Deleting project *{}*".format(AOS.osProject),'blue')
            project = re.findall(AOS.osProject,AOS.run_ssh_command("oc get project",ssh=False))
            if 0 < len(project):
                AOS.run_ssh_command("oc delete project {}".format(AOS.osProject),ssh=False)
                AOS.resource_validate("oc get projects", r"{}\s+".format(AOS.osProject), dstNum=0)

        outputs = AOS.run_ssh_command("oc get projects", ssh=False)
        project = re.findall(r"{}\s+".format(AOS.osProject), outputs)
        if 0 == len(project):
            cprint("Creating project *{}*".format(AOS.osProject),'blue')
            AOS.run_ssh_command("oc new-project {}".format(AOS.osProject),ssh=False)

        AOS.run_ssh_command("oc project {}".format(AOS.osProject), ssh=False)

    @staticmethod
    def loginedOnce():
        loginCMD = "oc login https://{0} -u {1} -p {2}".format(AOS.master, AOS.osUser, AOS.osPasswd)

        fExist = os.path.exists(os.path.expanduser('~/.kube/config'))
        if not fExist or not AOS.run_ssh_command("grep {} ~/.kube/config".format(AOS.master), ssh=False):
            cprint("[ IMPORTANT ] Need login this master once by manual! [ IMPORTANT ]",'red')
            cprint("Please run below login command line:",'red')
            cprint(loginCMD,'green')
            os.sys.exit()

    @classmethod
    def login_server(cls):
        AOS.loginedOnce()
        cprint('Log into OpenShift...','blue')
        AOS.run_ssh_command("oc login https://%s -u %s -p %s" % (AOS.master,AOS.osUser,AOS.osPasswd),ssh=False)
        AOS.add_project()

    @classmethod
    def get_subdomain(cls):
        masterConfig = os.path.join(AOS.masterConfigRoot, AOS.masterConfigFile)
        outputs = AOS.run_ssh_command("grep subdomain {}".format(masterConfig))
        subdomain = outputs.split()[-1].strip('"')
        return subdomain

    @classmethod
    def delete_oauth(cls):
        oauth = re.findall(r"kibana-proxy", AOS.run_ssh_command("oc get oauthclients", ssh=False))
        if 0 < len(oauth):
            AOS.run_ssh_command("oc delete oauthclients kibana-proxy", ssh=False)
            AOS.resource_validate("oc get oauthclients",r"kibana-proxy",dstNum=0)

    @classmethod
    def set_annotation(cls, imageStreams):
        cprint('Import tags for imagestreams...','blue')
        isList = [x.split()[0] for x in imageStreams.strip().split('\n')]
        for osIS in isList:
            AOS.run_ssh_command('oc patch imagestreams {}  -p {}'.format(osIS, pipes.quote('{"metadata":{"annotations":{"openshift.io/image.insecureRepository":"true"}}}')), ssh=False)
            if "registry.qe" not in AOS.imagePrefix:
              AOS.run_ssh_command('oc import-image {imgstream}:{version} --from={imgpre}{imgstream}:{version} --insecure=true'.format(imgstream=osIS, version=AOS.imageVersion, imgpre=AOS.imagePrefix), ssh=False)
            else:
#              AOS.run_ssh_command('oc import-image {imgstream}:{version} --from={imgpre}{imgstream}:{version} --insecure=true'.format(imgstream=osIS, version=AOS.imageVersion, imgpre=AOS.imagePrefix), ssh=False)
              AOS.run_ssh_command('oc tag --source=docker {}{}:{} {}:{}'.format(AOS.imagePrefix, osIS, AOS.imageVersion, osIS, AOS.imageVersion), ssh=False)
              AOS.run_ssh_command('oc import-image {imgpre}{imgstream}:{version} --insecure=true --confirm'.format(imgstream=osIS, version=AOS.imageVersion, imgpre=AOS.imagePrefix), ssh=False)
            time.sleep(5)

    @staticmethod
    def update_dc_for_registryqe_repo():
        dcs = AOS.run_ssh_command("oc get dc --no-headers -n {}".format(AOS.osProject), ssh=False)
        dcList = [x.split()[0] for x in dcs.strip().split('\n')]
        AOS.run_ssh_command("oc get dc logging-kibana -o yaml > dc.json", ssh=False)
        AOS.run_ssh_command("sed -i -e 's#image: logging-kibana#image: registry.qe.openshift.com/openshift3/logging-kibana:3.2.0#g' -e 's#image: openshift-auth-proxy#image: registry.qe.openshift.com/openshift3/logging-auth-proxy:3.2.0#g' dc.json", ssh=False)
        AOS.run_ssh_command("oc replace -f dc.json", ssh=False)
        AOS.run_ssh_command("oc get dc logging-fluentd -o yaml > dc.json", ssh=False)
        AOS.run_ssh_command("sed -i 's#image: logging-fluentd#image: registry.qe.openshift.com/openshift3/logging-fluentd:3.2.0#g' dc.json", ssh=False)
        AOS.run_ssh_command("oc replace -f dc.json", ssh=False)
        for dc in dcList:
            if "es" in dc:
               AOS.run_ssh_command("oc get dc {} -o yaml > dc.json".format(dc), ssh=False)
               AOS.run_ssh_command("sed -i 's#image: logging-elasticsearch#image: registry.qe.openshift.com/openshift3/logging-elasticsearch:3.2.0#g' dc.json", ssh=False)
               AOS.run_ssh_command("oc replace -f dc.json", ssh=False)

        AOS.run_ssh_command("rm -f dc.json", ssh=False)

    @staticmethod
    def add_pull_secret_for_registryqe_repo():
        AOS.run_ssh_command("oc secrets new-dockercfg mysecret --docker-server=registry.qe.openshift.com --docker-username=chunchen --docker-email=chunchen@redhat.com --docker-password={}".format(AOS.RegistryQEToken), ssh=False)
        AOS.run_ssh_command("oc secrets add aggregated-logging-elasticsearch mysecret --for=pull", ssh=False)
        AOS.run_ssh_command("oc secrets add aggregated-logging-fluentd mysecret --for=pull", ssh=False)
        AOS.run_ssh_command("oc secrets add aggregated-logging-kibana mysecret --for=pull", ssh=False)

    @classmethod
    def start_metrics_stack(cls):
        AOS.login_server()
        cprint("starting metrics stack...",'blue')
        AOS.run_ssh_command("oc create -f %s" % AOS.SAMetricsDeployer, ssh=False)
        AOS.do_permission("add-cluster-role-to-user", "cluster-reader", user="system:serviceaccount:%s:heapster" % AOS.osProject)
        AOS.do_permission("add-role-to-user","edit", user="system:serviceaccount:%s:metrics-deployer" % AOS.osProject)
        AOS.run_ssh_command("oc secrets new metrics-deployer nothing=/dev/null",ssh=False)
        subdomain = AOS.get_subdomain()
        AOS.run_ssh_command("oc process openshift//metrics-deployer-template -v HAWKULAR_METRICS_HOSTNAME=%s.%s,IMAGE_PREFIX=%s,IMAGE_VERSION=%s,USE_PERSISTENT_STORAGE=%s,MASTER_URL=https://%s,CASSANDRA_PV_SIZE=5Gi\
        |oc create -f -" % (AOS.hawkularMetricsAppname,subdomain,AOS.imagePrefix,AOS.imageVersion,AOS.enablePV,AOS.master), ssh=False)
        AOS.resource_validate("oc get pods -n %s" % AOS.osProject,r".*[heapster|hawkular].*Running.*")
        cprint("Success!","green")

    @classmethod
    def clean_logging_objects(cls):
        cprint("Cleanup resources related to logging stack...",'blue')
        AOS.run_ssh_command("oc delete all --selector logging-infra=kibana", ssh=False)
        AOS.run_ssh_command("oc delete all --selector logging-infra=fluentd", ssh=False)
        AOS.run_ssh_command("oc delete all --selector logging-infra=elasticsearch", ssh=False)
        AOS.run_ssh_command("oc delete all,sa --selector logging-infra=support", ssh=False)
        AOS.run_ssh_command("oc delete sa logging-deployer", ssh=False)
        AOS.run_ssh_command("oc delete secret logging-deployer logging-fluentd logging-elasticsearch logging-es-proxy logging-kibana logging-kibana-proxy logging-kibana-ops-proxy", ssh=False)
        AOS.run_ssh_command("oc delete ClusterRole daemonset-admin -n openshift && oc delete ClusterRole oauth-editor -n openshift")

    @classmethod
    def start_logging_stack(cls):
        AOS.login_server()
        AOS.do_permission("add-cluster-role-to-user", "cluster-admin")
        cprint("Start deploying logging stack pods...",'blue')
        AOS.clean_logging_objects()
        subdomain = AOS.get_subdomain()
        AOS.run_ssh_command("oc secrets new logging-deployer nothing=/dev/null",ssh=False)
        AOS.do_permission("add-scc-to-user","hostmount-anyuid",user="system:serviceaccount:{}:aggregated-logging-elasticsearch".format(AOS.osProject))

        if AOS.imageVersion > "3.2.0":
           AOS.run_ssh_command("oc new-app logging-deployer-account-template", ssh=False)
           AOS.do_permission("add-role-to-user","edit",user="--serviceaccount logging-deployer")
           AOS.do_permission("add-role-to-user","daemonset-admin",user="--serviceaccount logging-deployer")
           AOS.do_permission("add-cluster-role-to-user","oauth-editor",user="system:serviceaccount:{}:logging-deployer".format(AOS.osProject))
           AOS.do_permission("add-cluster-role-to-user","cluster-reader",user="system:serviceaccount:{}:aggregated-logging-fluentd".format(AOS.osProject))
           AOS.do_permission("add-scc-to-user","privileged",user="system:serviceaccount:{}:aggregated-logging-fluentd".format(AOS.osProject))
           AOS.run_ssh_command("oc label node --all logging-infra-fluentd=true --overwrite", ssh=False)
        else:
           AOS.delete_oauth()
           AOS.run_ssh_command('echo -e "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n    name: logging-deployer\nsecrets:\n- name: logging-deployer"| oc create -f -', ssh=False)
           AOS.do_permission("add-role-to-user","edit",user="system:serviceaccount:{}:logging-deployer".format(AOS.osProject))
           AOS.do_permission("add-cluster-role-to-user","cluster-reader",user="system:serviceaccount:{}:aggregated-logging-fluentd".format(AOS.osProject))
           AOS.do_permission("add-scc-to-user","privileged",user="system:serviceaccount:{}:aggregated-logging-fluentd".format(AOS.osProject))
           #AOS.do_permission("add-cluster-role-to-user","cluster-admin",user="system:serviceaccount:{}:logging-deployer".format(AOS.osProject))
           #AOS.do_permission("add-scc-to-user","hostmount-anyuid",user="system:serviceaccount:{}:aggregated-logging-fluentd".format(AOS.osProject))

        cmd = "oc process openshift//logging-deployer-template -v ENABLE_OPS_CLUSTER=false,IMAGE_PREFIX={prefix},KIBANA_HOSTNAME={kName}.{subdomain},KIBANA_OPS_HOSTNAME={opsName}.{subdomain},PUBLIC_MASTER_URL=https://{master},ES_INSTANCE_RAM={ram},ES_CLUSTER_SIZE={size},IMAGE_VERSION={version},MASTER_URL=https://{master},ES_PVC_SIZE={pvc_size}|oc create -f -"\
                                                                                         .format(prefix=AOS.imagePrefix,kName=AOS.kibanaAppname,\
                                                                                          subdomain=subdomain,opsName=AOS.kibanaOpsAppname,
                                                                                          master=AOS.master,ram=AOS.ESRam,pvc_size=AOS.ESPVCSize,\
                                                                                          size=AOS.ESClusterSize,version=AOS.imageVersion)
        AOS.run_ssh_command(cmd,ssh=False)
        AOS.resource_validate("oc get pods -n {}".format(AOS.osProject), r"logging-deployer.+Completed", dstNum=1)

        if AOS.imageVersion <= "3.2.0":
           AOS.run_ssh_command("oc process logging-support-template -n {project} -v IMAGE_VERSION={version}| oc create -n {project} -f -".format(project=AOS.osProject,version=AOS.imageVersion), ssh=False)
           imageStreams = AOS.run_ssh_command("oc get is --no-headers -n {}".format(AOS.osProject), ssh=False)
           if "registry.qe" in AOS.imagePrefix:
#              AOS.update_dc_for_registryqe_repo()
              AOS.add_pull_secret_for_registryqe_repo()
           AOS.set_annotation(imageStreams)

        AOS.resource_validate("oc get dc --no-headers -n {}".format(AOS.osProject), r"(logging-fluentd\s+|logging-kibana\s+|logging-es-\w+|logging-curator-\w+)", dstNum=3)

        if AOS.imageVersion <= "3.2.0":
           nodeNum = AOS.run_ssh_command("oc get node --no-headers 2>/dev/null | grep -v Disabled |grep -i -v Not | wc -l", ssh=False)
           AOS.run_ssh_command("oc scale dc/logging-fluentd --replicas={}".format(nodeNum), ssh=False)
           AOS.run_ssh_command("oc scale rc/logging-fluentd-1 --replicas={}".format(nodeNum), ssh=False)

        AOS.do_permission("remove-cluster-role-from-user", "cluster-admin")

        cprint("Success!","green")

    @staticmethod
    def clone_apiman_gitrepo():
        if os.path.exists("./origin-apiman"):
           AOS.run_ssh_command("pushd origin-apiman && git pull && popd",ssh=False)
        else:
           AOS.run_ssh_command("git clone https://github.com/openshift/origin-apiman.git",ssh=False)
        AOS.run_ssh_command("oc delete -f https://raw.githubusercontent.com/openshift/origin-apiman/master/deployer/deployer.yaml -n openshift")
    
    @staticmethod
    def get_inner_registry_svcIPPort():
        # 172.30.20.237:5000
        registryIpPort = AOS.run_ssh_command('oc get svc docker-registry --template="{{.spec.portalIP}}:{{ with index .spec.ports 0 }}{{ .port }}{{end}}"')
        return registryIpPort+"/apiman/"

    @classmethod
    def start_apiman_stack(cls):
        AOS.clone_apiman_gitrepo()
        AOS.login_server()
        cprint("starting APIMan stack...",'blue')
        imagePrefix = AOS.get_inner_registry_svcIPPort()
        AOS.run_ssh_command("oc new-app -f origin-apiman/hack/dev-builds.yaml", ssh=False)
        AOS.run_ssh_command("oc create -n openshift -f https://raw.githubusercontent.com/openshift/origin-apiman/master/deployer/deployer.yaml")
        AOS.run_ssh_command("oc secrets new apiman-deployer nothing=/dev/null", ssh=False)
        AOS.run_ssh_command("oc new-app apiman-deployer-account-template", ssh=False)
        AOS.do_permission("add-role-to-user", "edit", user="--serviceaccount apiman-deployer")
        AOS.do_permission("add-cluster-role-to-user", "cluster-reader", user="system:serviceaccount:%s:apiman-console" % AOS.osProject)
        AOS.do_permission("add-cluster-role-to-user", "cluster-reader", user="system:serviceaccount:%s:apiman-gateway" % AOS.osProject)
        subdomain = AOS.get_subdomain()
        AOS.run_ssh_command("oc new-app apiman-deployer-template -p GATEWAY_HOSTNAME=gateway.{subdm},CONSOLE_HOSTNAME=console.{subdm},PUBLIC_MASTER_URL=https://{osdm},ES_CLUSTER_SIZE=1,IMAGE_PREFIX={imgpre}".format(subdm=subdomain,osdm=AOS.master,imgpre=imagePrefix), ssh=False)
        AOS.resource_validate("oc get pods -n %s" % AOS.osProject,r"[apiman\-console|apiman\-curator|apiman\-es|apiman\-gateway].*Running.*", 4)
        cprint("Success!","green")
        cprint("Access APIMan Console via browser: ~/link.html", "green")

    @staticmethod
    def sudo_hack(cmd):
       if "root" != AOS.masterUser:
          return "sudo " + cmd
       elif "openshift" in cmd:
          return "openshift"
       return cmd

    @classmethod
    def start_origin_openshift(cls):
        cprint("Starting OpenShift Service...","blue")
        openshift = "/data/src/github.com/openshift/origin/_output/local/bin/linux/amd64/openshift"
        AOS.run_ssh_command("%s start --public-master=%s:8443 --write-config=/etc/origin" % (AOS.sudo_hack(openshift), AOS.master))
        #nodeConfigPath = outputs.rstrip().split()[-1]
        outputs = AOS.run_ssh_command("hostname")
        nodeConfigPath = '/etc/origin/node-' + outputs.strip()
        nodeConfig = os.path.join(nodeConfigPath,"node-config.yaml")
        masterConfig = os.path.join(AOS.masterConfigRoot, AOS.masterConfigFile)
        kubeConfig = os.path.join(AOS.masterConfigRoot, AOS.kubeConfigFile)
        AOS.run_ssh_command("%s -i -e '/loggingPublicURL:/d' -e '/metricsPublicURL:/d' %s" % (AOS.sudo_hack("sed"),masterConfig))
        AOS.run_ssh_command("%s openshift" % AOS.sudo_hack("killall"))
        AOS.run_ssh_command("echo export KUBECONFIG={kube} >> ~/.bashrc; {chd} o+rx {kube}; nohup {os} start --node-config={node} --master-config={master} &> openshift.log &".format(chd=AOS.sudo_hack("chmod"),os=AOS.sudo_hack(openshift),node=nodeConfig,master=masterConfig,kube=kubeConfig))
        AOS.resource_validate("oc get projects", r"Active", enableSsh=True)

        # For automation cases related admin role
        master = AOS.master.replace('.','-')
        AOS.run_ssh_command("oc config use-context default/%s:8443/system:admin && %s -p /root/.kube && %s /etc/origin/master/admin.kubeconfig /root/.kube/config" % (master,AOS.sudo_hack('mkdir'),AOS.sudo_hack('cp')))
        outputs = AOS.run_ssh_command("oc get pods -n default")
        allRunningPods = re.findall(r'docker-registry.*Running.*|router-1.*Running.*', outputs)
        lggtmpt = AOS.run_ssh_command("oc get template -n openshift --no-headers | grep logging", ssh=True)
        if not lggtmpt:
            AOS.run_ssh_command("oc create -f {} -n openshift".format(AOS.EFKDeployer), ssh=True)

        if 0 == len(allRunningPods):
            AOS.create_default_pods()
            AOS.create_imagestream_into_openshift_project()
            AOS.clone_metrics_and_logging_gitrepos()
            if AOS.pullLoggingMetricsImage:
               AOS.pull_metrics_and_logging_images()
        cprint("Success! OpenShift Server is UP. ^_^",'green')

    @staticmethod
    def clone_metrics_and_logging_gitrepos():
        cprint("Cloning logging/metrics/apiman git repos to %s under $HOME dir for building related images..." % AOS.master,'blue')
        cmd = "git clone https://github.com/openshift/origin-metrics.git; git clone https://github.com/openshift/origin-aggregated-logging.git; git clone https://github.com/openshift/origin-apiman.git"
        AOS.run_ssh_command(cmd)

    @staticmethod
    def create_imagestream_into_openshift_project():
        cprint("Creating basic imagestream and metrics/logging templates in *openshift* namespace...",'blue')
        cmd = "oc create -n openshift -f https://raw.githubusercontent.com/openshift/origin/master/examples/image-streams/image-streams-rhel7.json && oc create -n openshift -f https://raw.githubusercontent.com/openshift/origin-metrics/master/metrics.yaml && oc create -n openshift -f https://raw.githubusercontent.com/openshift/origin-aggregated-logging/master/deployment/deployer.yaml"
        AOS.run_ssh_command(cmd)

    @staticmethod
    def pull_metrics_and_logging_images():
        cprint("Pulling down metrics and logging images form DockerHub registry...",'blue')
        imagePrefixs = {"openshift/origin-","registry.access.redhat.com/openshift3/"}
        images = {"metrics-hawkular-metrics","metrics-heapster","metrics-cassandra","metrics-deployer",\
                  "logging-kibana","logging-fluentd","logging-elasticsearch","logging-auth-proxy","logging-deployment"}
        cmd = ';'.join([' '.join(['docker pull',imagePrefix+image]) for imagePrefix in imagePrefixs for image in images])
        AOS.run_ssh_command(cmd)

    @staticmethod
    def create_default_pods():
        # Backup: --images='openshift/origin-${component}:latest
        AOS.run_ssh_command("oc delete dc -n default; oc delete rc -n default; oc delete pods  -n default; oc delete svc -n default; oc delete imagestreams -n openshift; oc delete sa router -n default; oc delete clusterrolebinding router-router-role; oc delete sa registry -n default; oc delete clusterrolebinding registry-registry-role -n default")
        # Add permission for creating router
        AOS.run_ssh_command("oadm policy add-scc-to-user privileged system:serviceaccount:default:default")
        chmod = AOS.sudo_hack('chmod')
        cprint("Creating registry and router pods",'blue')
        cmd = 'export CURL_CA_BUNDLE=/etc/origin/master/ca.crt; \
                  {chd} a+rwX /etc/origin/master/admin.kubeconfig; \
                  {chd} +r /etc/origin/master/openshift-registry.kubeconfig; \
                  oc create serviceaccount registry -n default; \
                  oadm registry -n default --config=/etc/origin/master/admin.kubeconfig; \
                  oc create serviceaccount router -n default; \
                  oadm policy add-scc-to-user hostnetwork -z router;\
                  oadm policy add-cluster-role-to-user system:router system:serviceaccount:default:router; \
                  oadm  router --service-account=router'.format(chd=chmod)
        AOS.run_ssh_command(cmd)

    @classmethod
    def args_handler(cls):
        # Global options
        commonArgs = ArgumentParser(add_help=False)
        commonArgs.add_argument("-m", help="OpenShift server DNS,eg: ec2-52-23-180-133.compute-1.amazonaws.com")
        commonArgs.add_argument("--version", action="version", version="%(prog)s 1.0", help="Display version")
    
        # Options for sub-command
        subCommonArgs = ArgumentParser(add_help=False)
        subCommonArgs.add_argument('-p', help="Specify OpenShift project")
        subCommonArgs.add_argument('-d', action="store_true",\
                                         help="Delete OpenShift project and Re-create. Default is False")
        subCommonArgs.add_argument('--prefix',help="Image prefix, eg:brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888/openshift3/")
        subCommonArgs.add_argument('--mtag',help="Image tag, eg: latest")
    
        commands = ArgumentParser(parents=[commonArgs],description="Setup OpenShift on EC2 or Deploy metrics/logging stack")
        subCommands = commands.add_subparsers(title='subcommands:')
    
        # Sub-command for starting OpenShift server
        startos = subCommands.add_parser('startos', parents=[commonArgs],\
                                                    description="Start OpenShift server",\
                                                    help="start OpenShift service")
        startos.add_argument('--pull', action="store_true",\
                                       help="Docker pull the metrics and logging related images from DockerHub.Default is False")
        startos.set_defaults(subcommand=AOS.start_origin_openshift)
    
        # Sub-command for deploying metrics stack
        metrics = subCommands.add_parser('metrics',parents=[commonArgs,subCommonArgs],\
                                                   description="Deploy metrics stack pods",\
                                                   help="Deploy metrics stack pods")
        metrics.set_defaults(subcommand=AOS.start_metrics_stack)
    
        # Sub-command for deploying logging stack
        logging = subCommands.add_parser('logging', parents=[commonArgs,subCommonArgs],\
                                                    description="Deploy logging stack pods",\
                                                    help="Deploy logging stack pods")
        logging.set_defaults(subcommand=AOS.start_logging_stack)
    
        # Sub-command for deploying APIMan stack
        logging = subCommands.add_parser('apiman', parents=[commonArgs,subCommonArgs],\
                                                    description="Deploy APIMan stack pods",\
                                                    help="Deploy APIMan stack pods")
        logging.set_defaults(subcommand=AOS.start_apiman_stack)

        # Show current configurations
        logging = subCommands.add_parser('showcfg', parents=[commonArgs],\
                                                    description="Show current configurations",\
                                                    help="Show current configurations")
        logging.set_defaults(subcommand=AOS.show_current_config)

        args = commands.parse_args()
        if not 'show_current_config' == args.subcommand.__name__:
           AOS.check_validation(args)
     
        return args

if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal_handler)

    args = AOS.args_handler() 
    args.subcommand()
