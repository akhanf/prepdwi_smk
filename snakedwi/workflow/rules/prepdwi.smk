from snakebids import bids

wildcard_constraints:
    shell = "[0-9]+",



rule import_dwi:
    input: 
        nii = [re.sub('.nii.gz',ext,config['input_path']['dwi']) for ext in ['.nii.gz','.bval','.bvec','.json']]
    output:
        nii = multiext(bids(root='results',suffix='dwi', datatype='dwi',**config['input_wildcards']['dwi']),'.nii.gz','.bval','.bvec','.json')
    group: 'subj'
    run:
        for in_file,out_file in zip(input,output):
            shell('cp -v {in_file} {out_file}')

rule dwidenoise:
    input: multiext(bids(root='results',suffix='dwi',datatype='dwi',**config['input_wildcards']['dwi']),\
                    '.nii.gz','.bvec','.bval','.json')
    output: multiext(bids(root='results',suffix='dwi',desc='denoise',datatype='dwi',**config['input_wildcards']['dwi']),\
                    '.nii.gz','.bvec','.bval','.json')
    container: config['singularity']['prepdwi']
    log: bids(root='logs',suffix='denoise.log',**config['input_wildcards']['dwi'])
    group: 'subj'
    shell: 'dwidenoise {input[0]} {output[0]} 2> {log} && ' 
            'cp {input[1]} {output[1]} && '
            'cp {input[2]} {output[2]} && '
            'cp {input[3]} {output[3]}'


def get_degibbs_inputs (wildcards):
    # if input dwi at least 30 dirs, then grab denoised as input
    # else grab without denoising 
    import numpy as np
    in_dwi_bval = re.sub('.nii.gz','.bval',config['input_path']['dwi'].format(**wildcards))
    bvals = np.loadtxt(in_dwi_bval)
    if bvals.size < 30:
        prefix = bids(root='results',suffix='dwi',datatype='dwi',**wildcards)
    else:
        prefix = bids(root='results',suffix='dwi',datatype='dwi',desc='denoise',**wildcards)
    return multiext(prefix,'.nii.gz','.bvec','.bval','.json')
 
rule mrdegibbs:
    input: get_degibbs_inputs
    output: multiext(bids(root='results',suffix='dwi',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),\
                    '.nii.gz','.bvec','.bval','.json')
    container: config['singularity']['prepdwi']
#    log: bids(root='logs',suffix='degibbs.log',**config['input_wildcards']['dwi'])
    group: 'subj'
    shell: 'mrdegibbs {input[0]} {output[0]} && '#2> {log} && ' 
            'cp {input[1]} {output[1]} && '
            'cp {input[2]} {output[2]} && '
            'cp {input[3]} {output[3]}'


#now have nii with just the b0's, want to create the topup phase-encoding text files for each one:
rule get_phase_encode_txt:
    input:
        bzero_nii = bids(root='results',suffix='b0.nii.gz',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),
        json = bids(root='results',suffix='dwi.json',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi'])
    output:
        phenc_txt = bids(root='results',suffix='phenc.txt',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),
    group: 'subj'
    script: '../scripts/get_phase_encode_txt.py'
        


rule concat_phase_encode_txt:
    input:
        phenc_txts = lambda wildcards: expand(bids(root='results',suffix='phenc.txt',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output:
        phenc_concat = bids(root='results',suffix='phenc.txt',datatype='dwi',desc='degibbs',**config['subj_wildcards'])
    group: 'subj'
    shell: 'cat {input} > {output}'


#function for either concatenating (if multiple inputs) or copying
def get_concat_or_cp_cmd (wildcards, input, output):
    if len(input) > 1:
        cmd = f'mrcat {input} {output}'
    elif len(input) == 1:
        cmd = f'cp {input} {output}'
    else:
        #no inputs
        cmd = None
    return cmd


    
rule concat_bzeros:
    input:
        bzero_niis = lambda wildcards: expand(bids(root='results',suffix='b0.nii.gz',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    params:
        cmd = get_concat_or_cp_cmd
    output:
        bzero_concat = bids(root='results',suffix='concatb0.nii.gz',datatype='dwi',desc='degibbs',**config['subj_wildcards'])
    container: config['singularity']['prepdwi']
    log: bids(root='logs',suffix='concat_bzeros.log',**config['subj_wildcards'])
    group: 'subj'
    shell: '{params.cmd} 2> {log}'


#this rule should only run if there are multiple images
rule run_topup:
    input:
        bzero_concat = bids(root='results',suffix='concatb0.nii.gz',datatype='dwi',desc='degibbs',**config['subj_wildcards']),
        phenc_concat = bids(root='results',suffix='phenc.txt',datatype='dwi',desc='degibbs',**config['subj_wildcards'])
    params:
        out_prefix = bids(root='results',suffix='topup',datatype='dwi',**config['subj_wildcards']),
        config = 'b02b0.cnf' #this config sets the multi-res schedule and other params..
    output:
        bzero_corrected = bids(root='results',suffix='concatb0.nii.gz',desc='topup',datatype='dwi',**config['subj_wildcards']),
        fieldmap = bids(root='results',suffix='fmap.nii.gz',desc='topup',datatype='dwi',**config['subj_wildcards']),
        topup_fieldcoef = bids(root='results',suffix='topup_fieldcoef.nii.gz',datatype='dwi',**config['subj_wildcards']),
        topup_movpar = bids(root='results',suffix='topup_movpar.txt',datatype='dwi',**config['subj_wildcards']),
    container: config['singularity']['prepdwi']
    log: bids(root='logs',suffix='topup.log',**config['subj_wildcards'])
    group: 'subj'
    shell: 'topup --imain={input.bzero_concat} --datain={input.phenc_concat} --config={params.config}'
           ' --out={params.out_prefix} --iout={output.bzero_corrected} --fout={output.fieldmap} -v 2> {log}'


#this is for equal positive and negative blipped data - method=lsr --unused currently (jac method can be applied more generally)
rule apply_topup_lsr:
    input:
        dwi_niis = lambda wildcards: expand(bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards)),
        phenc_concat = bids(root='results',suffix='phenc.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        topup_fieldcoef = bids(root='results',suffix='topup_fieldcoef.nii.gz',datatype='dwi',**config['subj_wildcards']),
        topup_movpar = bids(root='results',suffix='topup_movpar.txt',datatype='dwi',**config['subj_wildcards']),
    params:
        #create comma-seperated list of dwi nii
        imain = lambda wildcards, input: ','.join(input.dwi_niis), 
        # create comma-sep list of indices 1-N
        inindex = lambda wildcards, input: ','.join([str(i) for i in range(1,len(input.dwi_niis)+1)]), 
        topup_prefix = bids(root='results',suffix='topup',datatype='dwi',**config['subj_wildcards']),
        out_prefix = 'dwi_topup',
    output: 
        dwi_topup = bids(root='results',suffix='dwi.nii.gz',desc='topup',method='lsr',datatype='dwi',**config['subj_wildcards'])
    container: config['singularity']['prepdwi']
    shadow: 'minimal'
    group: 'subj'
    shell: 'applytopup --verbose --datain={input.phenc_concat} --imain={params.imain} --inindex={params.inindex} '
           ' -t {params.topup_prefix} -o {params.out_prefix} && '
           ' fslmaths {params.out_prefix}.nii.gz {output.dwi_topup}'


rule apply_topup_jac:
    input:
        nii = bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['input_wildcards']['dwi']), 
        phenc_scan = bids(root='results',suffix='phenc.txt',datatype='dwi',desc='degibbs',**config['input_wildcards']['dwi']),
        phenc_concat = bids(root='results',suffix='phenc.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        topup_fieldcoef = bids(root='results',suffix='topup_fieldcoef.nii.gz',datatype='dwi',**config['subj_wildcards']),
        topup_movpar = bids(root='results',suffix='topup_movpar.txt',datatype='dwi',**config['subj_wildcards']),
    params:
        inindex = lambda wildcards: snakebids.get_filtered_ziplist_index(
                        config['input_zip_lists']['dwi'],wildcards,config['subj_wildcards']) +1,# adjust from 0- to 1-indexed
        topup_prefix = bids(root='results',suffix='topup',datatype='dwi',**config['subj_wildcards']),
    output: 
        nii = bids(root='results',suffix='dwi.nii.gz',desc='topup',method='jac',datatype='dwi',**config['input_wildcards']['dwi']), 
    container: config['singularity']['prepdwi']
    shadow: 'minimal'
    group: 'subj'
    shell: 
        ' applytopup --verbose --datain={input.phenc_concat} --imain={input.nii} --inindex={params.inindex} ' 
        ' -t {params.topup_prefix} -o dwi_topup --method=jac && mv dwi_topup.nii.gz {output.nii}'


#topup-corrected data is only used for brainmasking.. 
# here, use the jac method by default (later can decide if lsr approach can be used based on headers)
# with jac approach, the jac images need to be concatenated, then avgshell extracted

"""
rule cp_sidecars_topup_lsr:
    #TODO: BEST WAY TO TO EXEMPLAR DWI? 
    input: multiext(bids(root='results',suffix='dwi',desc='degibbs',datatype='dwi',**config['subj_wildcards'],**dwi_exemplar_dict),\
                '.bvec','.bval','.json')
    output: multiext(bids(root='results',suffix='dwi',desc='topup',method='lsr',datatype='dwi',**config['subj_wildcards']),\
                '.bvec','.bval','.json')
    run:
        for in_file,out_file in zip(input,output):
            shell('cp -v {in_file} {out_file}')
"""

rule cp_sidecars_topup_jac:
    input: multiext(bids(root='results',suffix='dwi',desc='degibbs',datatype='dwi',**config['subj_wildcards']),\
                '.bvec','.bval','.json')
    output: multiext(bids(root='results',suffix='dwi',desc='topup',method='jac',datatype='dwi',**config['subj_wildcards']),\
                '.bvec','.bval','.json')
    group: 'subj'
    run:
        for in_file,out_file in zip(input,output):
            shell('cp -v {in_file} {out_file}')

rule concat_dwi_topup_jac:
    input:
        dwi_niis = lambda wildcards: expand(bids(root='results',suffix='dwi.nii.gz',desc='topup',method='jac',datatype='dwi',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output:
        dwi_concat = bids(root='results',suffix='dwi.nii.gz',desc='topup',method='jac',datatype='dwi',**config['subj_wildcards'])
    container: config['singularity']['prepdwi']
    group: 'subj'
    shell: 'mrcat {input} {output}' 


rule get_eddy_index_txt:
    input:
        dwi_niis = lambda wildcards: expand(bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output:
        eddy_index_txt = bids(root='results',suffix='dwi.eddy_index.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
    group: 'subj'
    script: '../scripts/get_eddy_index_txt.py'
 
rule concat_degibbs_dwi:
    input:
        dwi_niis = lambda wildcards: expand(bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['input_wildcards']['dwi']),\
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output:
        dwi_concat = bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['subj_wildcards'])
    container: config['singularity']['prepdwi']
    log: bids(root='logs',suffix='concat_degibbs_dwi.log',**config['subj_wildcards'])
    group: 'subj'
    shell: 'mrcat {input} {output} 2> {log}' 

rule concat_runs_bvec:
    input:
        lambda wildcards: expand(bids(root='results',suffix='dwi.bvec',desc='{{desc}}',datatype='dwi',**config['input_wildcards']['dwi']),
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output: bids(root='results',suffix='dwi.bvec',desc='{desc}',datatype='dwi',**config['subj_wildcards'])
    group: 'subj'
    script: '../scripts/concat_bv.py' 

rule concat_runs_bval:
    input:
        lambda wildcards: expand(bids(root='results',suffix='dwi.bval',desc='{{desc}}',datatype='dwi',**config['input_wildcards']['dwi']),
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output: bids(root='results',suffix='dwi.bval',desc='{desc}',datatype='dwi',**config['subj_wildcards'])
    group: 'subj'
    script: '../scripts/concat_bv.py' 

#combines json files from multiple scans -- for now as a hack just copying first json over..
rule concat_runs_json:
    input:
        lambda wildcards: expand(bids(root='results',suffix='dwi.json',desc='{{desc}}',datatype='dwi',**config['input_wildcards']['dwi']),
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output: bids(root='results',suffix='dwi.json',desc='{desc}',datatype='dwi',**config['subj_wildcards'])
    group: 'subj'
    shell: 'cp {input[0]} {output}'
#    script: '../scripts/concat_json.py' 


rule get_shells_from_bvals:
    input: '{dwi_prefix}.bval'
    output: '{dwi_prefix}.shells.json'
    group: 'subj'
    script:
        '../scripts/get_shells_from_bvals.py'
 
#writes 4d file
rule get_shell_avgs:
    input: 
        dwi = '{dwi_prefix}.nii.gz',
        shells = '{dwi_prefix}.shells.json'
    output: 
        avgshells = '{dwi_prefix}.avgshells.nii.gz'
    group: 'subj'
    script:
        '../scripts/get_shell_avgs.py'

#this gets a particular shell (can use to get b0)
rule get_shell_avg:
    input:
        dwi = '{dwi_prefix}_dwi.nii.gz',
        shells = '{dwi_prefix}_dwi.shells.json'
    params:
        bval = '{shell}'
    output:
        avgshell = '{dwi_prefix}_b{shell}.nii.gz'
    group: 'subj'
    script:
        '../scripts/get_shell_avg.py'

#have multiple brainmasking workflows -- this rule picks the method chosen in the config file
def get_mask_for_eddy(wildcards):

    #first get name of method
    if wildcards.subject in config['masking']['custom']:
        method = config['masking']['custom'][wildcards.subject]
    else:
        method = config['masking']['default_method']

    #then get bids name of file 
    return bids(root='results',suffix='mask.nii.gz',desc='brain',method=method,datatype='dwi',**config['subj_wildcards'])


#generate qc snapshot for brain  mask 
rule qc_brainmask_for_eddy:
    input:
        img = bids(root='results',suffix='b0.nii.gz',desc='dwiref',datatype='dwi',**config['subj_wildcards']),
        seg = get_mask_for_eddy
    output:
#        png = bids(root='qc',subject='{subject}',suffix='mask.png',desc='brain'),
        png = report(bids(root='qc',suffix='mask.png',desc='brain',**config['subj_wildcards']),
                caption='../report/brainmask_dwi.rst',
                category='Brainmask'),

        html = bids(root='qc',suffix='mask.html',desc='brain',**config['subj_wildcards']),
#        html = report(bids(root='qc',subject='{subject}',suffix='dseg.html',atlas='{atlas}', from_='{template}'),
#                caption='../report/segqc.rst',
#                category='Segmentation QC',
#                subcategory='{atlas} Atlas from {template}'),
    group: 'subj'
    script: '../scripts/vis_qc_dseg.py'

    
rule get_slspec_txt:
    input:
        dwi_jsons = lambda wildcards: expand(bids(root='results',suffix='dwi.json',desc='degibbs',datatype='dwi',**config['input_wildcards']['dwi']),
                            zip,**snakebids.filter_list(config['input_zip_lists']['dwi'], wildcards))
    output:
        eddy_slspec_txt = bids(root='results',suffix='dwi.eddy_slspec.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
    group: 'subj'
    script: '../scripts/get_slspec_txt.py'


# --- this is where the choice of susceptibility distortion correction (SDC) is made --
# 
# get dwi reference for masking, registration -- either topup or degibbs b0
#  currently, if more than one dwi, we use topup, otherwise, no distortion correction (i.e. get degibbs)

#  TODO: implement other fieldmap based correction, and registration-based correction here too

def get_dwi_ref (wildcards):

    #this gets the number of DWI scans for this subject(session)
    filtered = snakebids.filter_list(config['input_zip_lists']['dwi'],wildcards)
    num_scans = len(filtered['subject'])
    
    if num_scans > 1 and not config['no_topup']:
        return bids(root='results',suffix='b0.nii.gz',desc='topup',method='jac',datatype='dwi',**config['subj_wildcards'])
    else:
        return bids(root='results',suffix='b0.nii.gz',desc='degibbs',datatype='dwi',**config['subj_wildcards'])
        

rule cp_dwi_ref:
    input: get_dwi_ref
    output: bids(root='results',suffix='b0.nii.gz',desc='dwiref',datatype='dwi',**config['subj_wildcards']),
    group: 'subj'
    shell: 'cp {input} {output}'    


def get_eddy_topup_input (wildcards):
     #this gets the number of DWI scans for this subject(session)
    filtered = snakebids.filter_list(config['input_zip_lists']['dwi'],wildcards)
    num_scans = len(filtered['subject'])
    
    if num_scans > 1 and not config['no_topup']:
        topup_inputs = { filename : bids(root='results',suffix=f'{filename}.nii.gz',datatype='dwi',**config['subj_wildcards']).format(**wildcards) for filename in ['topup_fieldcoef','topup_movpar']}
        return topup_inputs
    else:
        return None



def get_eddy_topup_opt (wildcards, input):
   
    #this gets the number of DWI scans for this subject(session)
    filtered = snakebids.filter_list(config['input_zip_lists']['dwi'],wildcards)
    num_scans = len(filtered['subject'])
    
    if num_scans > 1 and not config['no_topup']:
        topup_prefix = bids(root='results',suffix='topup',datatype='dwi',**config['subj_wildcards']).format(**wildcards)
        return f'--topup={topup_prefix}'
    else:
        return ''


def get_eddy_s2v_opts (wildcards, input):
    options = []
    if config['eddy_no_s2v']:
        options += [f'--{key}={value}' for (key,value) in config['eddy']['without_s2v'].items() if value is not None ]
    else:
        options += [f'--{key}={value}' for (key,value) in config['eddy']['with_s2v'].items() if value is not None ]            
    return ' '.join(options)

   
def get_eddy_slspec_input (wildcards):
    if config['eddy_no_s2v']:
        return {}
    else:
        return {'eddy_slspec_txt': bids(root='results',suffix='dwi.eddy_slspec.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards'])}

def get_eddy_slspec_opt (wildcards, input):
    if config['eddy_no_s2v']:
        return  ''
    else:
        return f'--slspec={input.eddy_slspec_txt}'

    
rule run_eddy:
    input:        
        unpack(get_eddy_slspec_input),
        dwi_concat = bids(root='results',suffix='dwi.nii.gz',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        phenc_concat = bids(root='results',suffix='phenc.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        eddy_index_txt = bids(root='results',suffix='dwi.eddy_index.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        brainmask = get_mask_for_eddy,
        bvals = bids(root='results',suffix='dwi.bval',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        bvecs = bids(root='results',suffix='dwi.bvec',desc='degibbs',datatype='dwi',**config['subj_wildcards'])
    params:
        #set eddy output prefix to 'dwi' inside the output folder
        out_prefix = lambda wildcards, output: os.path.join(output.out_folder,'dwi'),
        flags = ' '.join([f'--{key}' for (key,value) in config['eddy']['flags'].items() if value == True ] ),
        container = config['singularity']['fsl_603'],
        topup_opt = get_eddy_topup_opt,
        s2v_opts = get_eddy_s2v_opts,
        slspec_opt = get_eddy_slspec_opt,
    output:
        #eddy creates many files, so write them to a eddy subfolder instead
        out_folder = directory(bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards'])),
        dwi = os.path.join(bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards']),'dwi.nii.gz'),
        bvec = os.path.join(bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards']),'dwi.eddy_rotated_bvecs')
    threads: 16 #this needs to be set in order to avoid multiple gpus from executing
    resources:
        gpus = 1,
        time = 360, #6 hours (this is a conservative estimate, may be shorter)
        mem_mb = 32000,
    log: bids(root='logs',suffix='run_eddy.log',**config['subj_wildcards'])
    group: 'subj'
    shell: 'singularity exec --nv -e {params.container} eddy_cuda9.1 '
            ' --imain={input.dwi_concat} --mask={input.brainmask} '
            ' --acqp={input.phenc_concat} --index={input.eddy_index_txt} '
            ' --bvecs={input.bvecs} --bvals={input.bvals} '
            ' --out={params.out_prefix} '
            ' {params.s2v_opts} '
            ' {params.slspec_opt} '
            ' {params.topup_opt} '
            ' {params.flags}  &> {log}'


rule cp_eddy_outputs:
    input:
        #get nii.gz, bvec, and bval from eddy output
        dwi = os.path.join(bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards']),'dwi.nii.gz'),
        bvec = os.path.join(bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards']),'dwi.eddy_rotated_bvecs'),
        bval = bids(root='results',suffix='dwi.bval',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
    output:
        multiext(bids(root='results',suffix='dwi',desc='eddy',datatype='dwi',**config['subj_wildcards']),'.nii.gz','.bvec','.bval')
    group: 'subj'
    run:
        for in_file,out_file in zip(input,output):
            shell('cp -v {in_file} {out_file}')

rule eddy_quad:
    input:
        unpack(get_eddy_slspec_input),
        phenc_concat = bids(root='results',suffix='phenc.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        eddy_index_txt = bids(root='results',suffix='dwi.eddy_index.txt',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        brainmask = get_mask_for_eddy,
        bvals = bids(root='results',suffix='dwi.bval',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
        bvecs = bids(root='results',suffix='dwi.bvec',desc='degibbs',datatype='dwi',**config['subj_wildcards']),
#        fieldmap = bids(root='results',suffix='fmap.nii.gz',desc='topup',datatype='dwi',**config['subj_wildcards']),
        eddy_dir = bids(root='results',suffix='eddy',datatype='dwi',**config['subj_wildcards']),
    params: 
        eddy_prefix = lambda wildcards, input: os.path.join(input.eddy_dir,'dwi'),
        slspec_opt = get_eddy_slspec_opt,
    output:
        out_dir = directory(bids(root='results',suffix='eddy.qc',datatype='dwi',**config['subj_wildcards'])),
        eddy_qc_pdf = bids(root='results',suffix='eddy.qc/qc.pdf',datatype='dwi',**config['subj_wildcards'])
    container: config['singularity']['prepdwi']
    group: 'subj'
    shell: 
        'rmdir {output.out_dir} && '
        'eddy_quad {params.eddy_prefix} --eddyIdx={input.eddy_index_txt} --eddyParams={input.phenc_concat} '
        ' --mask={input.brainmask} --bvals={input.bvals} --bvecs={input.bvecs} --output-dir={output.out_dir} '
        ' {params.slspec_opt} --verbose'
        #' --field={input.fieldmap} ' #this seems to break it..

rule split_eddy_qc_report:
    input:
        eddy_qc_pdf = bids(root='results',suffix='eddy.qc/qc.pdf',datatype='dwi',**config['subj_wildcards'])
    output:
        report(directory(bids(root='results',suffix='eddy.qc_pages',datatype='dwi',**config['subj_wildcards'])),patterns=['{pagenum}.png'],caption="../report/eddy_qc.rst", category="eddy_qc",subcategory=bids(**config['subj_wildcards'],include_subject_dir=False,include_session_dir=False))
    group: 'subj'
    shell:
        'mkdir -p {output} && convert {input} {output}/%02d.png'
        

rule copy_inputs_for_bedpost:
    input: 
        dwi = bids(root='results',suffix='dwi.nii.gz',desc='eddy',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),
        bval = bids(root='results',suffix='dwi.bval',desc='eddy',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),
        bvec = bids(root='results',suffix='dwi.bvec',desc='eddy',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),
        brainmask = bids(root='results',suffix='mask.nii.gz',desc='brain',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),
    output:
        diff_dir = directory(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards'])),
        dwi = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'data.nii.gz'),
        brainmask = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'nodif_brain_mask.nii.gz'),
        bval = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'bvals'),
        bvec = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'bvecs'),
    group: 'subj'
    shell:
        'mkdir -p {output.diff_dir} && ' #could symlink instead??
        'cp {input.dwi} {output.dwi} && '
        'cp {input.brainmask} {output.brainmask} && '
        'cp {input.bval} {output.bval} && '
        'cp {input.bvec} {output.bvec} '
        
rule run_bedpost:
    input:
        diff_dir = bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),
        dwi = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'data.nii.gz'),
        brainmask = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'nodif_brain_mask.nii.gz'),
        bval = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'bvals'),
        bvec = os.path.join(bids(root='results',desc='eddy',suffix='diffusion',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards']),'bvecs'),
    params:
        container = config['singularity']['fsl_604']
    output:
        bedpost_dir = directory(bids(root='results',desc='eddy',suffix='diffusion.bedpostX',space='T1w',res=config['resample_dwi']['resample_scheme'],datatype='dwi',**config['subj_wildcards'])),
    group: 'subj'
    threads: 8 #this needs to be set in order to avoid multiple gpus from executing
    resources:
        gpus=1,
        mem_mb=16000,
        time=360,
    shell: 
        'singularity exec -e --nv {params.container} bedpostx_gpu {input.diff_dir} && '
        'rm -rf {output.bedpost_dir}/logs && '  #remove the logs to reduce # of files  
        'rm -rf {input.diff_dir}' # remove the input dir (copy of files) 


       
    #TODO: gradient correction (optional step -- only if gradient file is provided).. 
#  gradient_unwarp.py
#  reg_jacobian
#  convertwarp -> change this to wb_command -convert-warpfield  to get itk transforms 
#  applywarp -> change this to antsApplyTransforms


