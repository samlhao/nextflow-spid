#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/spid
========================================================================================
 nf-core/spid Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/spid
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-spid/main.nf --report abaumannii_report --assemblies 'asm/*.fasta' --se_reads 'se_data/*.fastq.gz' --pe_reads 'pe_data/*_{1,2}.fastq.gz' -profile docker --fasta s3://czb-spid/fasta/NZ_CP007727.1.fa --mlst_db s3://czb-spid/srst2/Klebsiella_pneumoniae.fasta --mlst_def s3://czb-spid/srst2/kpneumoniae.txt --amr_db s3://czb-spid/srst2/ARGannot_r2.fasta --forward_suffix _R1 --reverse_suffix _R2

    Mandatory arguments:
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Options:
      --se_reads                    Path to single-end reads (surrounded with quotes)
      --pe_reads                    Path to paired-end reads (surrounded with quotes)
      --assemblies                  Path to assemblies (surrounded with quotes)
      --genome                      Name of iGenomes reference
      --skip_trimming               Skip trimming with fastp if reads are already trimmed
      --forward_suffix              Forward read suffix, excluding extensions, for SRST2.
      --reverse_suffix              Reverse read suffix, excluding extensions, for SRST2.

    References:                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference
      --mlst_db                     Path to MLST fasta for SRST2
      --mlst_def                    Path to MLST definitions for SRST2
      --amr_db                      Path to AMR database for SRST2


    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail               Same as --email, except only send mail if the workflow is not successful
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      -resume                       Use cached results

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */


// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the channel below in a process, define the following:
//   input:
//   file fasta from ch_fasta
//
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if (params.fasta) {
    ch_fasta = file(params.fasta, checkIfExists: true) 
} else {
    ch_fasta = Channel.empty()
}


// Configure AMR database
// Create empty channels so processes have valid inputs when skipped
if (params.amr_db) {
    amr_db = file(params.amr_db)
}
// Configure MLST files
if (params.mlst_db && params.mlst_def) {
    mlst_db = file(params.mlst_db)
    mlst_def = file(params.mlst_def)
}



// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
  custom_runName = workflow.runName
}

if ( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if (params.se_reads) {
    Channel
        .fromFilePairs(params.se_reads, size: 1)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.se_reads}\nNB: Path needs to be enclosed in quotes!" }
        .into { se_read_files_fastqc; se_read_files_trimming }
    if (params.skip_trimming) {
        se_read_files_trimming.into { se_aln_ch; se_mlst_ch; se_amr_ch}
    }
}
else {
    Channel
        .empty()
        .into { se_read_files_fastqc; se_read_files_trimming; se_amr_results }
}

if (params.pe_reads) {
    Channel
        .fromFilePairs(params.pe_reads, size: 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.pe_reads}\nNB: Path needs to be enclosed in quotes!" }
        .into { pe_read_files_fastqc; pe_read_files_trimming }
    if (params.skip_trimming) {
        pe_read_files_trimming.into{pe_aln_ch; pe_mlst_ch; pe_amr_ch}
    }
}
else {
    Channel
        .empty()
        .into { pe_read_files_fastqc; pe_read_files_trimming }

}


if (params.assemblies) {
    Channel
        .fromFilePairs(params.assemblies, size: 1)
        .ifEmpty { exit 1, "Cannot find any assemblies matching: ${params.assemblies}\nNB: Path needs to be enclosed in quotes!" }
        .set { asm_ch }
}
else {
    Channel
        .empty()
        .set { asm_ch }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Single End Reads'] = params.se_reads
summary['Paired End Reads'] = params.pe_reads
summary['Assemblies']       = params.assemblies
summary['Fasta Ref']        = params.fasta
summary['AMR DB']           = params.amr_db
summary['MLST DB']          = params.mlst_db
summary['MLST Definitions'] = params.mlst_def
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile == 'awsbatch') {
  summary['AWS Region']     = params.awsregion
  summary['AWS Queue']      = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
  summary['E-mail Address']    = params.email
  summary['E-mail on failure'] = params.email_on_fail
  summary['MultiQC maxsize']   = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-spid-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/spid Workflow Summary'
    section_href: 'https://github.com/nf-core/spid'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}




/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".csv") > 0) filename
            else null
        }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    fastp --version &> v_fastp.txt
    raxmlHPC-PTHREADS -v > v_raxml.txt
    samtools --version > v_samtools.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/samples/$name", mode: 'copy'

    input:
    set val(name), file(reads) from se_read_files_fastqc.mix(pe_read_files_fastqc)

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc --threads $task.cpus $reads
    """
}

/*
 * STEP 2 - fastp
 */

process se_fastp {
    tag "$sample_id"
    label 'process_medium'
    label 'fastp'
    publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'

    input:
    tuple (sample_id, path (reads)) from se_read_files_trimming

    output:
    tuple (sample_id, path ('*_trimmed.fq.gz')) into (se_aln_ch, se_mlst_ch, se_amr_ch)
    path ("*.json") into se_fastp_results
    path ("*.html")

    when:
    !params.skip_trimming && params.se_reads

    script:
    """
    fastp -i ${reads[0]} -o ${reads[0].getSimpleName()}_trimmed.fq.gz -w ${task.cpus} --json ${reads[0].getSimpleName()}_fastp.json --html ${reads[0].getSimpleName()}_fastp.html
    """
}

process pe_fastp {
    tag "$sample_id"
    label 'process_medium'
    label 'fastp'
    publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'

    input:
    tuple (sample_id, path (reads)) from pe_read_files_trimming

    output:
    tuple (sample_id, path ('*_trimmed.fq.gz')) into (pe_aln_ch, pe_mlst_ch, pe_amr_ch)
    path ("*.json") into pe_fastp_results
    path ("*.html")

    when:
    !params.skip_trimming && params.pe_reads

    script:
    """
    fastp -i ${reads[0]} -I ${reads[1]} -o ${reads[0].getSimpleName()}_trimmed.fq.gz -O ${reads[1].getSimpleName()}_trimmed.fq.gz -w ${task.cpus} --json ${sample_id}_fastp.json --html ${sample_id}_fastp.html
    """
}

if (params.mlst_db && params.mlst_def && params.se_reads) {
  process se_srst2_mlst {
      tag "$sample_id"
      label 'srst2'
      label 'srst2_mlst'
      label 'process_low'
      publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'
  
      input:
      tuple (sample_id, path (reads)) from se_mlst_ch
      path(mlst_db)
      path(mlst_def)
  
      output:
      file "${sample_id}__mlst__${mlst_db.getSimpleName()}__results.txt" into se_mlst_results
  
      script:
      """
      mv ${reads[0]} ${sample_id}.fq.gz
  
      srst2 --output ${sample_id} \
      --input_se ${sample_id}.fq.gz \
      --mlst_db ${mlst_db} \
      --mlst_definitions ${mlst_def} \
      --mlst_delim "_" --log
      """
  }
}

if (params.mlst_db && params.mlst_def && params.pe_reads) {
  process pe_srst2_mlst {
      tag "$sample_id"
      label 'srst2'
      label 'srst2_mlst'
      label 'process_low'
      publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'
  
      input:
      tuple (sample_id, path (reads)) from pe_mlst_ch
      path(mlst_db)
      path(mlst_def)
      val forward_suffix from params.forward_suffix
      val reverse_suffix from params.reverse_suffix
  
      output:
      file "${sample_id}__mlst__${mlst_db.getSimpleName()}__results.txt" into pe_mlst_results
  
      script:
      """
      srst2 --output ${sample_id} \
      --input_pe ${reads[0]} ${reads[1]} \
      --mlst_db ${mlst_db} \
      --mlst_definitions ${mlst_def} \
      --mlst_delim "_" --forward ${forward_suffix}_trimmed --reverse ${reverse_suffix}_trimmed --log
      """
  }
}

if (params.amr_db && params.se_reads) {
  process se_srst2_amr {
      tag "$sample_id"
      label 'srst2'
      label 'srst2_amr'
      label 'process_low'
      publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'
  
      input:
      tuple (sample_id, path(reads)) from se_amr_ch
      path(amr_db)
  
      output:
      file ("${sample_id}__fullgenes__${amr_db.getSimpleName()}__results.txt") into se_fullgenes_results
      file ("${sample_id}__genes__${amr_db.getSimpleName()}__results.txt") into se_amr_results
  
      script:
      """
      mv ${reads[0]} ${sample_id}.fq.gz
      srst2 --output ${sample_id} \
       --input_se ${sample_id}.fq.gz \
       --gene_db ${amr_db} --log
      """
  }
}

if (params.amr_db && params.pe_reads) {
  process pe_srst2_amr {
      tag "$sample_id"
      label 'srst2'
      label 'srst2_amr'
      label 'process_low'
      publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'
  
      input:
      tuple (sample_id, path(reads)) from pe_amr_ch
      path(amr_db)
      val forward_suffix from params.forward_suffix
      val reverse_suffix from params.reverse_suffix
  
      output:
      file ("${sample_id}__fullgenes__${amr_db.getSimpleName()}__results.txt") into pe_fullgenes_results
      file ("${sample_id}__genes__${amr_db.getSimpleName()}__results.txt") into pe_amr_results
  
      script:
      """
      srst2 --output ${sample_id} \
       --input_pe ${reads[0]} ${reads[1]} \
       --gene_db ${amr_db} --log --forward ${forward_suffix}_trimmed --reverse ${reverse_suffix}_trimmed 
      """ 
  }
}


if ((params.mlst_db && params.mlst_def) || params.amr_db) {
  process compile_srst2 {
      label 'srst2'
      label 'process_low'
      publishDir "${params.outdir}/", mode: 'copy'
  
      input:
      path (amr_files) from se_amr_results.mix(pe_amr_results).collect()
      path (mlst_files) from se_mlst_results.mix(pe_mlst_results).collect()
  
      output:
      path("*compiledResults.txt")
  
      script:
      """
      srst2 --prev_output ${amr_files} ${mlst_files} --output srst2
      """
  }
}


process bgzip_fasta {
    label 'process_low'
    publishDir "${params.outdir}"

    input:
    path(fasta) from ch_fasta

    output:
    path("reference.fa.gz") into bgzip_fasta_ch

    when:
    params.fasta

    script:
    """
    mv ${fasta} reference.fa
    bgzip reference.fa
    """
}


process samtools_faidx {
    label 'process_low'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path(fasta_gz) from bgzip_fasta_ch

    output:
    tuple(path(fasta_gz), path("${fasta_gz}.fai")) into (fasta_gz_ch, asm_fasta_ch)

    when:
    params.fasta

    script:
    """
    samtools faidx ${fasta_gz}
    """
}

process generate_consensus_sr {
    tag "${sample_id}"
    label 'spid_docker'
    label 'process_medium'
    publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'

    input:
    tuple(path(fasta_gz), path(fasta_gz_idx)) from fasta_gz_ch
    tuple(sample_id, path(reads)) from se_aln_ch.mix(pe_aln_ch)

    output:
    path("${sample_id}.fa") into consensus_sr_ch
    path("${sample_id}.bam")
    path("${sample_id}.bam.bai")

    when:
    params.fasta

    script:
    """
    spid.jl align_short_reads ${sample_id} ${fasta_gz} ${reads} --threads ${task.cpus}
    """
}

process generate_consensus_asm {
    tag "${sample_id}"
    label 'spid_docker'
    label 'process_medium'
    publishDir "${params.outdir}/samples/${sample_id}", mode: 'copy'

    input:
    tuple (path(fasta_gz), path(fasta_gz_idx)) from asm_fasta_ch
    tuple (sample_id, path(asm)) from asm_ch

    output:
    path("${sample_id}.fa") into consensus_asm_ch
    path("${sample_id}.bam")
    path("${sample_id}.bam.bai")

    when:
    params.fasta && params.assemblies

    script:
    """
    spid.jl align_assembly ${sample_id} ${fasta_gz} ${asm} --threads ${task.cpus}
    """
}


process merge_sample_fastas {
    label 'spid_docker'
    label 'process_high'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path(consensus_fa) from consensus_sr_ch.mix(consensus_asm_ch).collect()

    output:
    tuple(path("merge_aligned_fastas.fa"), path("merge_aligned_fastas.variantsOnly.fa"), path("merge_aligned_fastas.fa.pairwise_diffs.csv")) into merge_sample_fastas_ch
    path("merge_aligned_fastas.variantsOnly.fa") into raxml_ch

    when:
    params.fasta

    script:
    """
    JULIA_NUM_THREADS=${task.cpus} spid.jl merge_alignments merge_aligned_fastas ${consensus_fa}
    """
}


process count_num_sites {
    label 'process_low'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    tuple(path(all_sites), path(variant_sites), path(pairwise_diffs)) from merge_sample_fastas_ch

    output:
    path("num_sites.json")

    when:
    params.fasta

    script:
    """
    #!/usr/bin/env python

    from Bio import SeqIO
    import json

    n_sites_all = len(next(SeqIO.parse("${all_sites}", "fasta")))
    n_sites_var = len(next(SeqIO.parse("${variant_sites}", "fasta")))
    with open("num_sites.json", "w") as f:
        json.dump({"n_sites_all": n_sites_all,
                   "n_sites_variant": n_sites_var}, f, indent=True)
    """
}


process raxml {
    publishDir "${params.outdir}", mode: 'copy'
    label 'process_high'

    input:
    path(fasta) from raxml_ch

    output:
    path("RAxML_bestTree.run_simple12345.${fasta}")

    when:
    params.fasta

    script:
    """
    raxmlHPC-PTHREADS -V -m ASC_GTRCAT -n run_simple12345.${fasta} -s ${fasta} -p 12345 -T 10 --asc-corr=lewis
    """
}



/*
 * STEP - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)
    path (fastp_results) from se_fastp_results.mix(pe_fastp_results).collect().ifEmpty([])

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config . ${fastp_results}
    """
}

/*
 * STEP - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/spid] Successful: $workflow.runName"
    if (!workflow.success) {
      subject = "[nf-core/spid] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/spid] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/spid] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
          if ( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/spid] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, email_address ].execute() << email_txt
          log.info "[nf-core/spid] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if (!output_d.exists()) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[nf-core/spid]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/spid]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/spid v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
